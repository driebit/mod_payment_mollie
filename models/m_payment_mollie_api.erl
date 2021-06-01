%% @copyright 2018-2021 Driebit BV
%% @doc API interface for Mollie PSP

%% Copyright 2018-2021 Driebit BV
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(m_payment_mollie_api).

-export([
    create/2,
    payment_sync/3,
    payment_sync_recurrent/1,

    is_test/1,
    api_key/1,
    webhook_url/2,
    payment_url/1,
    list_subscriptions/2,
    has_subscription/2,
    cancel_subscription/2
    ]).

-include("zotonic.hrl").
-include("mod_payment/include/payment.hrl").

-define(MOLLIE_API_URL, "https://api.mollie.nl/v1/").

-define(TIMEOUT_REQUEST, 10000).
-define(TIMEOUT_CONNECT, 5000).

%% @doc Create a new payment with Mollie (https://www.mollie.com/nl/docs/reference/payments/create)
create(PaymentId, Context) ->
    {ok, Payment} = m_payment:get(PaymentId, Context),
    case proplists:get_value(currency, Payment) of
        <<"EUR">> ->
            RedirectUrl = z_context:abs_url(
                z_dispatcher:url_for(
                    payment_psp_done,
                    [ {payment_nr, proplists:get_value(payment_nr, Payment)} ],
                    Context),
                Context),
            WebhookUrl = webhook_url(proplists:get_value(payment_nr, Payment), Context),
            Metadata = {struct, [
                {<<"payment_id">>, proplists:get_value(id, Payment)},
                {<<"payment_nr">>, proplists:get_value(payment_nr, Payment)}
            ]},
            Recurring =
                case proplists:get_value(recurring, Payment) of
                    true ->
                        [{recurringType, <<"first">>}];
                    false ->
                        []
                end,
            Args = [
                {amount, proplists:get_value(amount, Payment)},
                {description, valid_description( proplists:get_value(description, Payment) )},
                {webhookUrl, WebhookUrl},
                {redirectUrl, RedirectUrl},
                {metadata, iolist_to_binary([ mochijson2:encode(Metadata) ])}
            ] ++ Recurring,

            case maybe_add_custid(Payment, Args, Context) of
                {ok, ArgsCust} ->
                    case api_call(post, "payments", ArgsCust, Context) of
                        {ok, JSON} ->
                            <<"payment">> = maps:get(<<"resource">>, JSON),
                            MollieId = maps:get(<<"id">>, JSON),
                            Links = maps:get(<<"links">>, JSON),
                            PaymentUrl = maps:get(<<"paymentUrl">>, Links),
                            m_payment_log:log(
                                PaymentId,
                                <<"CREATED">>,
                                [
                                    {psp_module, mod_payment_mollie},
                                    {psp_external_log_id, MollieId},
                                    {description, <<"Created Mollie payment ", MollieId/binary>>},
                                    {request_result, JSON}
                                ],
                                Context),
                            {ok, #payment_psp_handler{
                                psp_module = mod_payment_mollie,
                                psp_external_id = MollieId,
                                psp_data = JSON,
                                redirect_uri = PaymentUrl
                            }};
                        {error, Error} ->
                            m_payment_log:log(
                              PaymentId,
                              <<"ERROR">>,
                              [
                               {psp_module, mod_payment_mollie},
                               {description, "API Error creating order with Mollie"},
                               {request_result, Error},
                               {request_args, Args}
                              ],
                              Context),
                            lager:error("API error creating mollie payment for #~p: ~p", [PaymentId, Error]),
                            {error, Error}
                    end;
                {error, _} = Error ->
                    Error
            end;
        Currency ->
            lager:error("Mollie payment request with non EUR currency: ~p", [Currency]),
            {error, {currency, only_eur}}
    end.

maybe_add_custid(Payment, Args, Context) ->
    case proplists:get_value(user_id, Payment) of
        undefined ->
            {ok, Args};
        UserId when is_integer(UserId) ->
            case ensure_mollie_customer_id(UserId, Context) of
                {ok, CustomerId} ->
                    {ok, [ {customerId, CustomerId} | Args ]};
                {error, _} = Error ->
                    Error
            end
    end.

valid_description(<<>>) -> <<"Payment">>;
valid_description(undefined) -> <<"Payment">>;
valid_description(D) when is_binary(D) -> D.


%% @doc Allow special hostname for the webhook, useful for testing.
webhook_url(PaymentNr, Context) ->
    Path = z_dispatcher:url_for(mollie_payment_webhook, [ {payment_nr, PaymentNr} ], Context),
    case m_config:get_value(mod_payment_mollie, webhook_host, Context) of
        <<"http", _/binary>> = Host -> <<Host/binary, Path/binary>>;
        _ -> z_context:abs_url(Path, Context)
    end.

-spec payment_url(binary()) -> binary().
payment_url(MollieId) ->
    <<"https://www.mollie.com/dashboard/payments/", (z_convert:to_binary(MollieId))/binary>>.


%% @doc Pull all payments from Mollie (since the previous pull) and sync them to our payment table.
-spec payment_sync_recurrent(z:context()) -> ok | {error, term()}.
payment_sync_recurrent(Context) ->
    Oldest = z_convert:to_binary( m_config:get_value(mod_payment_mollie, sync_periodic, Context) ),
    case fetch_payments_since(Oldest, undefined, [], Context) of
        {ok, []} ->
            ok;
        {ok, ExtPayments} ->
            lists:foreach(
                fun(ExtPayment) ->
                    handle_missed_recurrent(ExtPayment, Context)
                end,
                lists:reverse(ExtPayments)),
            #{ <<"createdDatetime">> := Newest } = hd(ExtPayments),
            m_config:set_value(mod_payment_mollie, sync_periodic, Newest, Context),
            ok;
        {error, _} = Error ->
            Error
    end.

fetch_payments_since(Oldest, NextLink, Acc, Context) ->
    Url = case NextLink of
        undefined -> "payments?count=250";
        _ -> z_convert:to_list(NextLink)
    end,
    case api_call(get, Url, [], Context) of
        {ok, #{ <<"data">> := Payments } = JSON} ->
            Newer = lists:filter(
                fun(P) ->
                    status_date(P) >= Oldest
                end,
                Payments),
            Acc1 = Acc ++ Newer,
            case Newer of
                [] ->
                    {ok, Acc1};
                _ ->
                    case maps:get(<<"links">>, JSON, undefined) of
                        #{ <<"next">> := Next } when is_binary(Next) ->
                            fetch_payments_since(Oldest, Next, Acc1, Context);
                        _ ->
                            {ok, Acc1}
                    end
            end;
        {error, _} = Error ->
            Error
    end.

handle_missed_recurrent(#{ <<"recurringType">> := <<"recurring">> } = JSON, Context) ->
    #{
        <<"id">> := ExtId,
        <<"links">> := #{
            <<"webhookUrl">> := WebhookUrl
        }
    } = JSON,
    [ WebhookUrl1 | _ ] = binary:split(WebhookUrl, <<"?">>),
    PaymentNr = lists:last( binary:split(WebhookUrl1, <<"/">>, [ global ])),
    case m_payment:get(PaymentNr, Context) of
        {ok, Payment} ->
            case proplists:get_value(psp_module, Payment) of
                mod_payment_mollie ->
                    % Fetch the status from Mollie
                    PaymentId = proplists:get_value(id, Payment),
                    m_payment_log:log(
                        PaymentId,
                        <<"WEBHOOK">>,
                        [
                           {psp_module, mod_payment_mollie},
                           {description, "New webhook payment info"},
                           {payment, JSON}
                        ],
                        Context),
                    handle_new_payment(PaymentId, Payment, JSON, Context);
                PSP ->
                    lager:error("Payment PSP Mollie webhook call for unknown PSP ~p / ~p: ~p", [PaymentNr, ExtId, PSP]),
                    {error, notfound}
            end;
        {error, notfound} ->
            lager:error("Payment PSP Mollie webhook call with unknown id ~p / ~p", [PaymentNr, ExtId]),
            {error, notfound};
        {error, _} = Error ->
            lager:error("Payment PSP Mollie webhook call with id ~p / ~p, fetching payment error: ~p", [PaymentNr, ExtId, Error]),
            Error
    end;
handle_missed_recurrent(_NonRecurringPayment, _Context) ->
    ok.


%% @doc Pull the payment status from Mollie.
-spec payment_sync(binary() | integer(), binary(), z:context()) -> ok | {error, notfound|term()}.
payment_sync(PaymentNrOrId, ExtId, Context) ->
    case m_payment:get(PaymentNrOrId, Context) of
        {ok, Payment} ->
            case proplists:get_value(psp_module, Payment) of
                mod_payment_mollie ->
                    % Fetch the status from Mollie
                    PaymentId = proplists:get_value(id, Payment),
                    lager:info("Payment PSP Mollie webhook call for payment #~p", [PaymentId]),
                    case api_call(get, "payments/" ++ z_convert:to_list(ExtId), [], Context) of
                        {ok, #{ <<"resource">> := <<"payment">> } = JSON} ->
                            m_payment_log:log(
                                PaymentId,
                                <<"WEBHOOK">>,
                                [
                                   {psp_module, mod_payment_mollie},
                                   {description, "New webhook payment info"},
                                   {payment, JSON}
                                ],
                                Context),
                            handle_new_payment(PaymentId, Payment, JSON, Context);
                        {error, Error} ->
                            %% Log an error with the payment
                            m_payment_log:log(
                                PaymentId,
                                <<"ERROR">>,
                                [
                                    {psp_module, mod_payment_mollie},
                                    {description, "API Error fetching status from Mollie"},
                                    {request_result, Error}
                                ],
                                Context),
                            lager:error("API error creating mollie payment for #~p: ~p", [PaymentId, Error]),
                            Error
                    end;
                PSP ->
                    lager:error("Payment PSP Mollie webhook call for unknown PSP ~p / ~p: ~p", [PaymentNrOrId, ExtId, PSP]),
                    {error, notfound}
            end;
        {error, notfound} ->
            lager:error("Payment PSP Mollie webhook call with unknown id ~p / ~p", [PaymentNrOrId, ExtId]),
            {error, notfound};
        {error, _} = Error ->
            lager:error("Payment PSP Mollie webhook call with id ~p / ~p, fetching payment error: ~p", [PaymentNrOrId, ExtId, Error]),
            Error
    end.

handle_new_payment(PaymentId, Payment, #{ <<"recurringType">> := <<"recurring">> } = JSON, Context) ->
    % A recurring payment for an existing payment.
    % The given Payment MUST have 'recurring' set.
    #{
        <<"id">> := ExtId,
        <<"status">> := Status,
        <<"subscriptionId">> := _SubscriptionId,
        <<"amount">> := Amount,
        <<"description">> := Description
    } = JSON,
    % Create a new payment, referring to the PaymentId
    Currency = proplists:get_value(currency, Payment),
    AmountNr = z_convert:to_float(Amount),
    DateTime = z_convert:to_datetime( status_date(JSON) ),
    case m_payment:get_by_psp(mod_payment_mollie, ExtId, Context) of
        {ok, Payment} ->
            PaymentId = proplists:get_value(id, Payment),
            update_payment_status(PaymentId, Status, DateTime, Context);
        {error, notfound} ->
            case m_payment:insert_recurring(PaymentId, DateTime, Currency, AmountNr, Context) of
                {ok, NewPaymentId} ->
                    PSPHandler = #payment_psp_handler{
                        psp_module = mod_payment_mollie,
                        psp_external_id = ExtId,
                        psp_payment_description = Description,
                        psp_data = JSON
                    },
                    ok = m_payment:update_psp_handler(NewPaymentId, PSPHandler, Context),
                    update_payment_status(NewPaymentId, Status, DateTime, Context);
                {error, _} = Error ->
                    lager:error("Payment PSP Mollie could not insert recurring payment for payment #~p: ~p ~p", [PaymentId, Error, JSON]),
                    Error
            end
    end;
handle_new_payment(PaymentId, Payment, #{ <<"recurringType">> := <<"first">> } = JSON, Context) ->
    % First recurring payment for an existing payment - start the subscription
    #{
        <<"status">> := Status
    } = JSON,
    DateTime = z_convert:to_datetime( status_date(JSON) ),
    case update_payment_status(PaymentId, Status, DateTime, Context) of
        ok ->
            case Status of
                <<"paid">> -> create_subscription(Payment, Context);
                _ -> ok
            end;
        {error, _} = Error ->
            Error
    end;
handle_new_payment(PaymentId, _Payment, JSON, Context) ->
    #{
        <<"status">> := Status,
        <<"amountRefunded">> := _AmountRefunded
    } = JSON,
    lager:info("Payment PSP Mollie got status ~p for payment #~p",
               [Status, PaymentId]),
    m_payment_log:log(
      PaymentId,
      <<"STATUS">>,
      [
        {psp_module, mod_payment_mollie},
        {description, "New payment status"},
        {status, JSON}
      ],
      Context),
    % UPDATE OUR ORDER STATUS
    DateTime = z_convert:to_datetime( status_date(JSON) ),
    update_payment_status(PaymentId, Status, DateTime, Context).


status_date(#{ <<"expiredDatetime">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(#{ <<"failedDatetime">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(#{ <<"cancelledDatetime">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(#{ <<"paidDatetime">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(#{ <<"createdDatetime">> := Date }) when is_binary(Date), Date =/= <<>> -> Date.

% Status is one of: open cancelled expired failed pending paid paidout refunded charged_back
update_payment_status(PaymentId, <<"open">>, Date, Context) ->         mod_payment:set_payment_status(PaymentId, new, Date, Context);
update_payment_status(PaymentId, <<"cancelled">>, Date, Context) ->    mod_payment:set_payment_status(PaymentId, cancelled, Date, Context);
update_payment_status(PaymentId, <<"canceled">>, Date, Context) ->     mod_payment:set_payment_status(PaymentId, cancelled, Date, Context);
update_payment_status(PaymentId, <<"expired">>, Date, Context) ->      mod_payment:set_payment_status(PaymentId, failed, Date, Context);
update_payment_status(PaymentId, <<"failed">>, Date, Context) ->       mod_payment:set_payment_status(PaymentId, failed, Date, Context);
update_payment_status(PaymentId, <<"pending">>, Date, Context) ->      mod_payment:set_payment_status(PaymentId, pending, Date, Context);
update_payment_status(PaymentId, <<"paid">>, Date, Context) ->         mod_payment:set_payment_status(PaymentId, paid, Date, Context);
update_payment_status(PaymentId, <<"paidout">>, Date, Context) ->      mod_payment:set_payment_status(PaymentId, paid, Date, Context);
update_payment_status(PaymentId, <<"refunded">>, Date, Context) ->     mod_payment:set_payment_status(PaymentId, refunded, Date, Context);
update_payment_status(PaymentId, <<"charged_back">>, Date, Context) -> mod_payment:set_payment_status(PaymentId, refunded, Date, Context);
update_payment_status(PaymentId, Status, _Date, _Context) ->
    lager:error("Mollie payment status is uknown: ~p (for payment #~p)", [ Status, PaymentId ]),
    ok.

api_call(Method, Endpoint, Args, Context) ->
    case api_key(Context) of
        {ok, ApiKey} ->
            Url = case Endpoint of
                <<"https:", _/binary>> -> z_convert:to_list(Endpoint);
                _ -> ?MOLLIE_API_URL ++ z_convert:to_list(Endpoint)
            end,
            Hs = [
                {"Authorization", "Bearer " ++ z_convert:to_list(ApiKey)}
            ],
            Request = case Method of
                          get ->
                              {Url, Hs};
                          _ ->
                              FormData = lists:map(
                                           fun
                                               ({K,V}) ->
                                                          {z_convert:to_list(K), z_convert:to_list(V)}
                                                  end,
                                           Args),
                              Body = mochiweb_util:urlencode(FormData),
                              {Url, Hs, "application/x-www-form-urlencoded", Body}
                      end,
            lager:debug("Making API call to Mollie: ~p~n", [Request]),
            case httpc:request(
                    Method, Request,
                    [ {autoredirect, true}, {relaxed, false}, {timeout, ?TIMEOUT_REQUEST}, {connect_timeout, ?TIMEOUT_CONNECT} ],
                    [ {sync, true}, {body_format, binary} ])
            of
                {ok, {{_, X20x, _}, Headers, Payload}} when ((X20x >= 200) and (X20x < 400)) ->
                    case proplists:get_value("content-type", Headers) of
                        undefined ->
                            {ok, Payload};
                        ContentType ->
                            case binary:match(list_to_binary(ContentType), <<"json">>) of
                                nomatch ->
                                    {ok, Payload};
                                _ ->
                                    Props = jsx:decode(Payload, [return_maps]),
                                    {ok, Props}
                            end
                    end;
                {ok, {{_, Code, _}, Headers, Payload}} ->
                    lager:error("Mollie API call to ~p returns ~p: ~p ~p", [ Url, Code, Payload, Headers]),
                    {error, Code};
                {error, Reason} = Error ->
                    lager:error("Mollie API call to ~p returns error ~p", [ Url, Reason]),
                    Error
            end;
        {error, notfound} ->
            {error, api_key_not_set}
    end.

%% @doc Check if the current API Key is live or test.
-spec is_test( z:context() ) -> boolean().
is_test(Context) ->
    case api_key(Context) of
        <<"test_", _/binary>> -> true;
        _ -> false
    end.

-spec api_key(z:context()) -> {ok, binary()} | {error, notfound}.
api_key(Context) ->
    case m_config:get_value(mod_payment_mollie, api_key, Context) of
        undefined -> {error, notfound};
        <<>> -> {error, notfound};
        ApiKey -> {ok, ApiKey}
    end.


valid_mandate(#{ <<"status">> := <<"pending">> }) -> true;
valid_mandate(#{ <<"status">> := <<"valid">> }) -> true;
valid_mandate(_) -> false.


create_subscription(Payment, Context) ->
    {id, PaymentId} = proplists:lookup(id, Payment),
    {user_id, UserId} = proplists:lookup(user_id, Payment),
    case proplists:get_value(psp_data, Payment) of
        #{
            <<"recurringType">> := <<"first">>,
            <<"customerId">> := CustomerId
        } ->
            case api_call(get, "customers/" ++ z_convert:to_list(CustomerId) ++ "/mandates", [], Context) of
                {ok, Response} ->
                    Mandates = maps:get(<<"data">>, Response, []),
                    case lists:filter(fun valid_mandate/1, Mandates) of
                        [] ->
                            ok;
                        _ ->
                            {{Year, Month, Day}, _} = calendar:local_time(),
                            YearFromNow = io_lib:format("~4..0w-~2..0w-~2..0w", [Year + 1, Month, Day]),
                            Email = z_convert:to_binary( m_rsc:p_no_acl(UserId, email, Context) ),
                            WebhookUrl = webhook_url(proplists:get_value(payment_nr, Payment), Context),
                            Args = [
                                {amount, proplists:get_value(amount, Payment)},
                                {interval, <<"12 months">>},
                                {startDate, list_to_binary(YearFromNow)},
                                {webhookUrl, WebhookUrl},
                                {description, <<"Subscription for ", Email/binary, " - ", CustomerId/binary>>}
                            ],
                            case api_call(post, "customers/" ++ z_convert:to_list(CustomerId) ++ "/subscriptions",
                                          Args, Context)
                            of
                                {ok, Sub} ->
                                    m_payment_log:log(
                                        PaymentId,
                                        <<"SUBSCRIPTION">>,
                                        [
                                            {psp_module, mod_payment_mollie},
                                            {description, <<"Created subscription">>},
                                            {request_result, Sub}
                                        ],
                                        Context),
                                    ok;
                                {error, _} = Error ->
                                    m_payment_log:log(
                                        PaymentId,
                                        <<"ERROR">>,
                                        [
                                            {psp_module, mod_payment_mollie},
                                            {description, <<"API Error creating subscription">>},
                                            {request_result, Error}
                                        ],
                                        Context),
                                    Error
                            end
                    end;
                {error, _} = Error ->
                    % Log an error with the payment
                    m_payment_log:log(
                        PaymentId,
                        "ERROR",
                        [
                            {psp_module, mod_payment_mollie},
                            {description, <<"API Error fetching mandates from Mollie">>},
                            {request_result, Error}
                        ],
                        Context),
                    lager:error("API error creating mollie subscription for payment ~p (user ~p): ~p",
                                [ PaymentId, UserId, Error ]),
                    Error
            end;
        PspData ->
            % Log an error with the payment
            m_payment_log:log(
                PaymentId,
                <<"ERROR">>,
                [
                    {psp_module, mod_payment_mollie},
                    {description, <<"Could not create subscription: PSP data missing recurringType and/or customerId">>}
                ],
                Context),
            lager:error("Mollie payment PSP data missing recurringType and/or customerId, payment ~p (user ~p): ~p",
                        [ PaymentId, UserId, PspData ]),
            {error, pspdata}
    end.


list_subscriptions(UserId, Context) ->
    CustIds = mollie_customer_ids(UserId, true, Context),
    try
        Subs = lists:map(
            fun(CustId) ->
                case mollie_list_subscriptions(CustId, Context) of
                    {ok, S} -> S;
                    {error, _} = E -> throw(E)
                end
            end,
            CustIds),
        {ok, lists:map(fun parse_sub/1, lists:flatten(Subs))}
    catch
        throw:{error, _} = E -> E
    end.


mollie_list_subscriptions(CustId, Context) ->
    case api_call(get, "customers/" ++ z_convert:to_list(CustId) ++ "/subscriptions?count=250", [], Context) of
        {ok, #{ <<"data">> := Data } = Result} ->
            Links = maps:get(<<"links">>, Result, #{}),
            case mollie_list_subscriptions_next(Links, Context) of
                {ok, NextData} ->
                    {ok, Data ++ NextData};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

mollie_list_subscriptions_next(#{ <<"next">> := Next }, Context) when is_binary(Next), Next =/= <<>> ->
    case api_call(get, Next, [], Context) of
        {ok, #{ <<"data">> := Data, <<"links">> := Links }} ->
            case mollie_list_subscriptions_next(Links, Context) of
                {ok, NextData} ->
                    {ok, Data ++ NextData};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
mollie_list_subscriptions_next(#{}, _Context) ->
    {ok, []}.


parse_sub(#{
        <<"resource">> := <<"subscription">>,
        <<"id">> := SubId,
        <<"customerId">> := CustId,
        <<"startDate">> := Start,
        <<"cancelledDatetime">> := Cancelled,
        <<"amount">> := Amount,
        <<"interval">> := Interval,
        <<"description">> := Description
    }) ->
    #{
        id => {mollie_subscription, CustId, SubId},
        is_valid => is_null(Cancelled),
        start_date => to_date(Start),
        end_date => to_date(Cancelled),
        description => Description,
        interval => Interval,
        amount => z_convert:to_float(Amount)
    }.

is_null(undefined) -> true;
is_null(null) -> true;
is_null(<<>>) -> true;
is_null(_) -> false.

to_date(undefined) -> undefined;
to_date(null) -> undefined;
to_date(D) -> z_datetime:to_datetime(D).


has_subscription(UserId, Context) ->
    case list_subscriptions(UserId, Context) of
        {ok, Subs} ->
            lists:any(fun is_subscription_active/1, Subs);
        {error, _} ->
            false
    end.

is_subscription_active(#{ end_date := undefined }) -> false;
is_subscription_active(#{ end_date := _}) -> true.


cancel_subscription({mollie_subscription, CustId, SubId}, Context) ->
    case api_call(delete, "customers/" ++
                      z_convert:to_list(CustId) ++
                      "/subscriptions/" ++
                      z_convert:to_list(SubId),
                  [], Context) of
        {ok, _} ->
            ok;
        {error, 410} ->
            lager:info("API error cancelling mollie subscription for #~p: ~p (already canceled)", [CustId, 410]),
            ok;
        {error, Error} ->
            lager:error("API error cancelling mollie subscription for #~p: ~p", [CustId, Error]),
            Error
    end;
cancel_subscription(UserId, Context) when is_integer(UserId) ->
    case list_subscriptions(UserId, Context) of
        {ok, Subs} ->
            lists:foldl(
                fun
                    (#{ id := SubId }, ok) ->
                        cancel_subscription(SubId, Context);
                    (_, {error, _} = Error) ->
                        Error
                end,
                ok,
                Subs);
        {error, _} = Error ->
            Error
    end.


%% @doc Find the most recent valid customer id for a given user or create a new customer
-spec ensure_mollie_customer_id( m_rsc:resource_id(), z:context() ) -> {ok, binary()} | {error, term()}.
ensure_mollie_customer_id(UserId, Context) ->
    case m_rsc:exists(UserId, Context) of
        true ->
            case mollie_customer_id(UserId, false, Context) of
                {ok, CustId} ->
                    {ok, CustId};
                {error, enoent} ->
                    ContextSudo = z_acl:sudo(Context),
                    Email = m_rsc:p_no_acl(UserId, email, Context),
                    {Name, _Context} = z_template:render_to_iolist("_name.tpl", [ {id, UserId} ], ContextSudo),
                    Args = [
                        {name, iolist_to_binary(Name)},
                        {email, Email}
                    ],
                    case api_call(post, "customers", Args, Context) of
                        {ok, Json} ->
                            {ok, maps:get(<<"id">>, Json)};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        false ->
            {error, resource_does_not_exist}
    end.


%% @doc Find the most recent valid customer id for a given user
-spec mollie_customer_id( m_rsc:resource_id(), boolean(), z:context() ) -> {ok, binary()} | {error, term()}.
mollie_customer_id(UserId, OnlyRecurrent, Context) ->
    CustIds = mollie_customer_ids(UserId, OnlyRecurrent, Context),
    first_valid_custid(CustIds, Context).

first_valid_custid([], _Context) ->
    {error, enoent};
first_valid_custid([ CustomerId | CustIds ], Context) ->
    case api_call(get, "customers/" ++ z_convert:to_list(CustomerId), [], Context) of
        {ok, _Cust} ->
            {ok, CustomerId};
        {error, 404} ->
            first_valid_custid(CustIds, Context);
        {error, 410} ->
            first_valid_custid(CustIds, Context);
        {error, _} = Error ->
            Error
    end.


%% @doc List all Mollie customer ids for the given user.
%% The newest created customer id is listed first.
-spec mollie_customer_ids( m_rsc:resource_id(), boolean(), z:context() ) -> [ binary() ].
mollie_customer_ids(UserId, OnlyRecurrent, Context) ->
    Payments = m_payment:list_user(UserId, Context),
    CustIds = lists:foldl(
        fun(Payment, Acc) ->
            case proplists:get_value(psp_module, Payment) of
                mod_payment_mollie ->
                    case proplists:get_value(psp_data, Payment) of
                        #{
                            <<"customerId">> := CustId
                        } = PspData when is_binary(CustId) ->
                            RecType = maps:get(<<"recurringType">>, PspData, <<>>),
                            if
                                not OnlyRecurrent orelse (RecType =/= <<>>) ->
                                    case lists:member(CustId, Acc) of
                                        true -> Acc;
                                        false -> [ CustId | Acc ]
                                    end;
                                true ->
                                    Acc
                            end;
                        _ ->
                            Acc

                    end;
                _ ->
                    Acc
            end
        end,
        [],
        Payments),
    lists:reverse(CustIds).
