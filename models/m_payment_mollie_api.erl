%% @copyright 2018-2024 Driebit BV
%% @doc API interface for Mollie PSP
%% @end

%% Copyright 2018-2024 Driebit BV
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

    payment_sync_webhook/3,
    payment_sync_periodic/1,
    payment_sync_recent_pending/1,
    payment_sync/2,

    customer_sync/2,

    is_test/1,
    api_key/1,
    webhook_url/2,
    payment_url/1,
    list_subscriptions/2,
    has_subscription/2,
    cancel_subscription/2
    ]).

% Testing
-export([
    ]).


-include("zotonic.hrl").
-include("mod_payment/include/payment.hrl").

-define(MOLLIE_API_URL, "https://api.mollie.nl/v2/").

-define(TIMEOUT_REQUEST, 10000).
-define(TIMEOUT_CONNECT, 5000).

%% @doc Create a new payment with Mollie (https://www.mollie.com/nl/docs/reference/payments/create)
create(PaymentId, Context) ->
    {ok, Payment} = m_payment:get(PaymentId, Context),
    case proplists:lookup(currency, Payment) of
        {currency, <<"EUR">>} ->
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
                case proplists:get_value(is_recurring_start, Payment) of
                    true ->
                        [{sequenceType, <<"first">>}];
                    false ->
                        []
                end,
            Args = [
                {'amount[value]', filter_format_price:format_price(proplists:get_value(amount, Payment), Context)},
                {'amount[currency]', proplists:get_value(currency, Payment, <<"EUR">>)},
                {description, valid_description( proplists:get_value(description, Payment) )},
                {webhookUrl, WebhookUrl},
                {redirectUrl, RedirectUrl},
                {metadata, iolist_to_binary([ mochijson2:encode(Metadata) ])}
            ] ++ Recurring,

            case maybe_add_custid(Payment, Args, Context) of
                {ok, ArgsCust} ->
                    case api_call(post, "payments", ArgsCust, Context) of
                        {ok, #{
                                <<"resource">> := <<"payment">>,
                                <<"id">> := MollieId,
                                <<"_links">> := #{
                                    <<"checkout">> := #{
                                        <<"href">> := PaymentUrl
                                    }
                                }
                        } = JSON} ->
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
                        {ok, JSON} ->
                            m_payment_log:log(
                              PaymentId,
                              <<"ERROR">>,
                              [
                               {psp_module, mod_payment_mollie},
                               {description, "API Unexpected result creating payment with Mollie"},
                               {request_json, JSON},
                               {request_args, Args}
                              ],
                              Context),
                            lager:error("API unexpected result creating mollie payment for #~p: ~p", [PaymentId, JSON]),
                            {error, unexpected_result};
                        {error, Error} ->
                            m_payment_log:log(
                              PaymentId,
                              <<"ERROR">>,
                              [
                               {psp_module, mod_payment_mollie},
                               {description, "API Error creating payment with Mollie"},
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
        {currency, Currency} ->
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
    case z_convert:to_binary(m_config:get_value(mod_payment_mollie, webhook_host, Context)) of
        <<"http:", _/binary>> = Host -> <<Host/binary, Path/binary>>;
        <<"https:", _/binary>> = Host -> <<Host/binary, Path/binary>>;
        _ -> z_context:abs_url(Path, Context)
    end.

%% @doc Split payment nr from the webhook url.
webhook_url2payment(undefined) ->
    undefined;
webhook_url2payment(WebhookUrl) ->
    [ WebhookUrl1 | _ ] = binary:split(WebhookUrl, <<"?">>),
    case lists:last( binary:split(WebhookUrl1, <<"/">>, [ global ])) of
        <<>> -> undefined;
        PaymentNr -> PaymentNr
    end.

-spec payment_url(binary()|string()) -> binary().
payment_url(MollieId) ->
    <<"https://www.mollie.com/dashboard/payments/", (z_convert:to_binary(MollieId))/binary>>.


%% @doc Fetch the payment info from Mollie, to ensure that a specific payment is synchronized with
%% the information at Mollie.  Useful for pending/new payments where the webhook call failed.
-spec payment_sync(integer(), z:context()) -> ok | {error, term()}.
payment_sync(PaymentId, Context) when is_integer(PaymentId) ->
    case m_payment:get(PaymentId, Context) of
        {ok, Payment} ->
            case proplists:lookup(psp_module, Payment) of
                {psp_module, mod_payment_mollie} ->
                    {psp_external_id, ExtPaymentId} = proplists:lookup(psp_external_id, Payment),
                    case api_call(get, "payments/" ++ z_convert:to_list(ExtPaymentId), [], Context) of
                        {ok, #{
                                <<"resource">> := <<"payment">>
                            } = ThisPaymentJSON} ->
                            handle_payment_sync(ThisPaymentJSON, Context);
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
                {psp_module, _} ->
                    {error, psp_module}
            end;
        {error, _} = Error ->
            Error
    end.


%% @doc Update all 'pending' and 'new' payments in our payments table that were created in the
%% last month. This to ensure that pending/new payments are updated within an acceptable
%% period, even when the webhook call is missed.
-spec payment_sync_recent_pending(z:context()) -> ok | {error, term()}.
payment_sync_recent_pending(Context) ->
    Payments = z_db:q("
        select id
        from payment
        where psp_module = 'mod_payment_mollie'
          and status in ('new', 'pending')
          and created > now() - interval '1 month'
        ", Context),
    lists:foreach(
        fun({PaymentId}) ->
            payment_sync(PaymentId, Context)
        end,
        Payments).

%% @doc Pull all payments from Mollie (since the previous pull) and sync them to our payment table.
-spec payment_sync_periodic(z:context()) -> ok | {error, term()}.
payment_sync_periodic(Context) ->
    Oldest = z_convert:to_binary( m_config:get_value(mod_payment_mollie, sync_periodic, Context) ),
    case fetch_payments_since_loop(Oldest, undefined, [], Context) of
        {ok, []} ->
            ok;
        {ok, ExtPayments} ->
            lists:foreach(
                fun(ExtPayment) ->
                    handle_payment_sync(ExtPayment, Context)
                end,
                lists:reverse(ExtPayments)),
            CreationDates = lists:map(
                fun(#{ <<"createdAt">> := C }) -> C end,
                ExtPayments),
            Newest = lists:max(CreationDates),
            m_config:set_value(mod_payment_mollie, sync_periodic, Newest, Context),
            ok;
        {error, _} = Error ->
            Error
    end.

fetch_payments_since_loop(Oldest, NextLink, Acc, Context) ->
    Url = case NextLink of
        undefined -> "payments?limit=250";
        _ -> NextLink
    end,
    case api_call(get, Url, [], Context) of
        {ok, #{ <<"_embedded">> := #{ <<"payments">> := Payments } } = JSON} ->
            Newer = lists:filter(
                fun(P) ->
                    Status = payment_status(P),
                    status_date(Status, P) >= Oldest
                end,
                Payments),
            Acc1 = Acc ++ Newer,
            case Newer of
                [] ->
                    {ok, Acc1};
                _ ->
                    case maps:get(<<"_links">>, JSON, undefined) of
                        #{ <<"next">> := #{ <<"href">> := Next } } when is_binary(Next) ->
                            fetch_payments_since_loop(Oldest, Next, Acc1, Context);
                        _ ->
                            {ok, Acc1}
                    end
            end;
        {error, _} = Error ->
            Error
    end.

handle_payment_sync(ThisPaymentJSON, Context) ->
    % Payments have the webhook which has the payment-number of the first payment starting a sequence
    % or of the oneoff payment.
    #{
        <<"id">> := ExtId,
        <<"webhookUrl">> := WebhookUrl
    } = ThisPaymentJSON,
    FirstPaymentNr = webhook_url2payment(WebhookUrl),
    case m_payment:get(FirstPaymentNr, Context) of
        {ok, FirstPayment} ->
            % This is the original payment starting the sequence
            case proplists:lookup(psp_module, FirstPayment) of
                {psp_module, mod_payment_mollie} ->
                    % Fetch the status from Mollie
                    {id, FirstPaymentId} = proplists:lookup(id, FirstPayment),
                    m_payment_log:log(
                        FirstPaymentId,
                        <<"SYNC">>,
                        [
                           {psp_module, mod_payment_mollie},
                           {description, "Sync of payment info"},
                           {payment, ThisPaymentJSON}
                        ],
                        Context),
                    % Simulate the webhook call
                    handle_payment_update(FirstPaymentId, FirstPayment, ThisPaymentJSON, Context);
                {psp_module, PSP} ->
                    lager:error("Payment PSP Mollie webhook call for unknown PSP ~p / ~p: ~p",
                                [FirstPaymentNr, ExtId, PSP]),
                    {error, notfound}
            end;
        {error, notfound} ->
            lager:error("Payment PSP Mollie webhook call with unknown id ~p / ~p",
                        [FirstPaymentNr, ExtId]),
            {error, notfound};
        {error, _} = Error ->
            lager:error("Payment PSP Mollie webhook call with id ~p / ~p, fetching payment error: ~p",
                        [FirstPaymentNr, ExtId, Error]),
            Error
    end.


%% @doc Pull the payment status from Mollie. Used to synchronize a payment with the data
%% at Mollie. This is only a pull for update, not for fetching missing payments at Mollie.
%% Used for fetching information about new and pending payments.
-spec payment_sync_webhook(binary(), binary(), z:context()) -> ok | {error, notfound|term()}.
payment_sync_webhook(FirstPaymentNr, ExtPaymentId, Context) when is_binary(FirstPaymentNr) ->
    case m_payment:get(FirstPaymentNr, Context) of
        {ok, FirstPayment} ->
            case proplists:lookup(psp_module, FirstPayment) of
                {psp_module, mod_payment_mollie} ->
                    % Fetch the status from Mollie
                    {id, FirstPaymentId} = proplists:lookup(id, FirstPayment),
                    lager:info("Payment PSP Mollie webhook call for payment #~p", [FirstPaymentId]),
                    case api_call(get, "payments/" ++ z_convert:to_list(ExtPaymentId), [], Context) of
                        {ok, #{
                                <<"resource">> := <<"payment">>
                            } = ThisPaymentJSON} ->
                            m_payment_log:log(
                                FirstPaymentId,
                                <<"WEBHOOK">>,
                                [
                                   {psp_module, mod_payment_mollie},
                                   {description, "New webhook payment info"},
                                   {payment, ThisPaymentJSON}
                                ],
                                Context),
                            handle_payment_update(FirstPaymentId, FirstPayment, ThisPaymentJSON, Context);
                        {error, Error} ->
                            %% Log an error with the payment
                            m_payment_log:log(
                                FirstPaymentId,
                                <<"ERROR">>,
                                [
                                    {psp_module, mod_payment_mollie},
                                    {description, "API Error fetching status from Mollie"},
                                    {request_result, Error}
                                ],
                                Context),
                            lager:error("API error creating mollie payment for #~p: ~p", [FirstPaymentId, Error]),
                            Error
                    end;
                {psp_module, PSP} ->
                    lager:error("Payment PSP Mollie webhook call for unknown PSP ~p / ~p: ~p", [FirstPaymentNr, ExtPaymentId, PSP]),
                    {error, notfound}
            end;
        {error, notfound} ->
            lager:error("Payment PSP Mollie webhook call with unknown id ~p / ~p", [FirstPaymentNr, ExtPaymentId]),
            {error, notfound};
        {error, _} = Error ->
            lager:error("Payment PSP Mollie webhook call with id ~p / ~p, fetching payment error: ~p", [FirstPaymentNr, ExtPaymentId, Error]),
            Error
    end.


handle_payment_update(FirstPaymentId, _FirstPayment, #{ <<"sequenceType">> := <<"recurring">> } = JSON, Context) ->
    % A recurring payment for an existing (first) payment.
    % The given (first) Payment MUST have 'recurring' set.
    #{
        <<"id">> := ExtId,
        <<"subscriptionId">> := _SubscriptionId,
        <<"amount">> := #{
            <<"currency">> := Currency,
            <<"value">> := Amount
        },
        <<"description">> := Description
    } = JSON,
    Status = payment_status(JSON),
    % Create a new payment, referring to the PaymentId
    AmountNr = z_convert:to_float(Amount),
    DateTime = z_convert:to_datetime( status_date(Status, JSON) ),
    case m_payment:get_by_psp(mod_payment_mollie, ExtId, Context) of
        {ok, RecurringPayment} ->
            % Update the status of an already imported recurring payment.
            % This payment is linked to the first payment.
            {id, RecurringPaymentId} = proplists:lookup(id, RecurringPayment),
            {status, PrevStatus} = proplists:lookup(status, RecurringPayment),
            case is_status_equal(Status, PrevStatus) of
                true -> ok;
                false -> update_payment_status(RecurringPaymentId, Status, DateTime, Context)
            end;
        {error, notfound} ->
            % New recurring payment for an existing first payment.
            % Insert a new payment in our tables and the update that payment with
            % the newly received status.
            case m_payment:insert_recurring_payment(FirstPaymentId, DateTime, Currency, AmountNr, Context) of
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
                    lager:error("Payment PSP Mollie could not insert received recurring payment for first payment #~p: ~p ~p",
                                [FirstPaymentId, Error, JSON]),
                    Error
            end
    end;
handle_payment_update(FirstPaymentId, FirstPayment, #{ <<"sequenceType">> := <<"first">> } = JSON, Context) ->
    % First recurring payment for an existing payment - if moved to paid then start the subscription
    Status = payment_status(JSON),
    DateTime = z_convert:to_datetime( status_date(Status, JSON) ),
    {status, PrevStatus} = proplists:lookup(status, FirstPayment),
    case is_status_equal(Status, PrevStatus) of
        true ->
            ok;
        false ->
            case update_payment_status(FirstPaymentId, Status, DateTime, Context) of
                ok when Status =:= <<"paid">> -> maybe_create_subscription(FirstPayment, Context);
                ok -> ok;
                {error, _} = Error -> Error
            end
    end;
handle_payment_update(OneOffPaymentId, _OneOffPayment, JSON, Context) ->
    Status = payment_status(JSON),
    lager:info("Payment PSP Mollie got status ~p for payment #~p",
               [Status, OneOffPaymentId]),
    m_payment_log:log(
        OneOffPaymentId,
        <<"STATUS">>,
        [
            {psp_module, mod_payment_mollie},
            {description, "New payment status"},
            {status, JSON}
        ],
        Context),
    % UPDATE OUR ORDER STATUS
    DateTime = z_convert:to_datetime( status_date(Status, JSON) ),
    update_payment_status(OneOffPaymentId, Status, DateTime, Context).


%% Derived statuses from Mollie v2 API need special date handling:
%% - charged_back: No specific date field available, use current time
%% - refunded: Refund date is in the refund object (not payment), use current time
%% - paidout: Use settledAt if available, otherwise current time
status_date(<<"charged_back">>, _JSON) -> calendar:universal_time();
status_date(<<"refunded">>, _JSON) -> calendar:universal_time();
status_date(<<"paidout">>, #{ <<"settledAt">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(<<"paidout">>, _JSON) -> calendar:universal_time();
status_date(_Status, #{ <<"expiredAt">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(_Status, #{ <<"failedAt">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(_Status, #{ <<"canceledAt">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(_Status, #{ <<"paidAt">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(_Status, #{ <<"createdAt">> := Date }) when is_binary(Date), Date =/= <<>> -> Date.


%% In the Mollie v2 API the statuses 'refunded', 'charged_back' and 'paidout' are removed.
%% The final status is now 'paid'. The removed statuses need to be derived from the presence
%% of links in the _links object.
payment_status(#{ <<"status">> := <<"paid">>, <<"_links">> := #{ <<"chargebacks">> := #{ <<"href">> := _ }}}) -> <<"charged_back">>;
payment_status(#{ <<"status">> := <<"paid">>, <<"_links">> := #{ <<"refunds">> := #{ <<"href">> := _ }}}) -> <<"refunded">>;
payment_status(#{ <<"status">> := <<"paid">>, <<"_links">> := #{ <<"settlement">> := #{ <<"href">> := _ }}}) -> <<"paidout">>;
payment_status(#{ <<"status">> := Status }) -> Status.


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
    lager:error("Mollie payment status is unknown: ~p (for payment #~p)", [ Status, PaymentId ]),
    ok.

is_status_equal(StatusA, StatusB) ->
    StatusA1 = map_status(z_convert:to_binary(StatusA)),
    StatusB1 = map_status(z_convert:to_binary(StatusB)),
    StatusA1 =:= StatusB1.

map_status(<<"canceled">>) -> <<"cancelled">>;
map_status(<<"expired">>) -> <<"failed">>;
map_status(<<"open">>) -> <<"new">>;
map_status(<<"paidout">>) -> <<"paid">>;
map_status(<<"charged_back">>) -> <<"refunded">>;
map_status(Status) -> Status.

api_call(Method, Endpoint, Args, Context) ->
    case api_key(Context) of
        {ok, ApiKey} ->
            Url = case Endpoint of
                <<"https:", _/binary>> -> z_convert:to_list(Endpoint);
                "https:" ++ _ -> Endpoint;
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
                                            fun({K,V}) ->
                                                {z_convert:to_list(K), z_convert:to_list(V)}
                                            end,
                                            Args),
                              Body = mochiweb_util:urlencode(FormData),
                              {Url, Hs, "application/x-www-form-urlencoded", Body}
                      end,
            lager:debug("Making API call to Mollie: ~p~n", [Request]),
            case httpc:request(
                    Method, Request,
                    [ {autoredirect, true}, {relaxed, false},
                      {timeout, ?TIMEOUT_REQUEST}, {connect_timeout, ?TIMEOUT_CONNECT} ],
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
                {ok, {{_, 410, _}, Headers, Payload}} ->
                    lager:debug("Mollie API call to ~p returns ~p: ~p ~p", [ Url, 410, Payload, Headers]),
                    {error, 410};
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


is_valid_mandate(#{ <<"status">> := <<"pending">> }) -> true;
is_valid_mandate(#{ <<"status">> := <<"valid">> }) -> true;
is_valid_mandate(_) -> false.


maybe_create_subscription(FirstPayment, Context) ->
    case proplists:get_value(psp_data, FirstPayment) of
        #{
            <<"sequenceType">> := <<"first">>,
            <<"customerId">> := CustomerId
        } ->
            % v2 API data
            maybe_create_subscription_1(FirstPayment, CustomerId, Context);
        #{
            <<"recurringType">> := <<"first">>,
            <<"customerId">> := CustomerId
        } ->
            % v1 API data
            maybe_create_subscription_1(FirstPayment, CustomerId, Context);
        PspData ->
            % Log an error with the payment
            {id, PaymentId} = proplists:lookup(id, FirstPayment),
            {user_id, UserId} = proplists:lookup(user_id, FirstPayment),
            m_payment_log:log(
                PaymentId,
                <<"ERROR">>,
                [
                    {psp_module, mod_payment_mollie},
                    {description, <<"Could not create a subscription: PSP data missing sequenceType and/or customerId">>}
                ],
                Context),
            lager:error("Mollie payment PSP data missing sequenceType and/or customerId, payment ~p (user ~p): ~p",
                        [ PaymentId, UserId, PspData ]),
            {error, pspdata}
    end.

maybe_create_subscription_1(FirstPayment, CustomerId, Context) ->
    {created, Created} = proplists:lookup(created, FirstPayment),
    RecentDate = z_datetime:prev_month(calendar:universal_time(), 2),
    if
        RecentDate < Created ->
            create_subscription_1(FirstPayment, CustomerId, Context);
        true ->
            ok
    end.

create_subscription_1(FirstPayment, CustomerId, Context) ->
    {id, PaymentId} = proplists:lookup(id, FirstPayment),
    {user_id, UserId} = proplists:lookup(user_id, FirstPayment),
    case api_call(get, "customers/" ++ z_convert:to_list(CustomerId) ++ "/mandates", [], Context) of
        {ok, #{
            <<"_embedded">> := #{
                <<"mandates">> := Mandates
            }
        }} ->
            case lists:any(fun is_valid_mandate/1, Mandates) of
                true ->
                    {{Year, Month, Day}, _} = calendar:local_time(),
                    YearFromNow = io_lib:format("~4..0w-~2..0w-~2..0w", [Year + 1, Month, Day]),
                    Email = z_convert:to_binary( m_rsc:p_no_acl(UserId, email_raw, Context) ),
                    WebhookUrl = webhook_url(proplists:get_value(payment_nr, FirstPayment), Context),
                    Args = [
                        {'amount[value]', filter_format_price:format_price(proplists:get_value(amount, FirstPayment), Context)},
                        {'amount[currency]', proplists:get_value(currency, FirstPayment, <<"EUR">>)},
                        {interval, <<"12 months">>},
                        {startDate, list_to_binary(YearFromNow)},
                        {webhookUrl, WebhookUrl},
                        {description, <<"Subscription for ", Email/binary, " - ", CustomerId/binary>>}
                    ],
                    case api_call(post, "customers/" ++ z_convert:to_list(CustomerId) ++ "/subscriptions",
                                  Args, Context)
                    of
                        {ok, #{
                            <<"resource">> := <<"subscription">>,
                            <<"status">> := SubStatus
                        } = Sub} ->
                            lager:info("Mollie created subscription for customer ~p (~p)",
                                       [ CustomerId, SubStatus ]),
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
                        {ok, JSON} ->
                            m_payment_log:log(
                                PaymentId,
                                <<"ERROR">>,
                                [
                                    {psp_module, mod_payment_mollie},
                                    {description, <<"API Unexpected result creating subscription from Mollie">>},
                                    {request_result, JSON}
                                ],
                                Context),
                            lager:error("API unexpected result creating subscription for payment ~p (user ~p): ~p",
                                        [ PaymentId, UserId, JSON ]),
                            {error, unexpected_result};
                        {error, Reason} = Error ->
                            lager:error("Mollie error creating subscription for customer ~p: ~p",
                                        [ CustomerId, Reason ]),
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
                    end;
                false ->
                    lager:info("Mollie created a subscription request but no valid mandates for customer ~p (payment ~p)",
                               [ CustomerId, PaymentId ]),
                    m_payment_log:log(
                        PaymentId,
                        <<"WARNING">>,
                        [
                            {psp_module, mod_payment_mollie},
                            {description, <<"Cannot create a subscription - no valid mandates">>}
                        ],
                        Context),
                    ok
            end;
        {ok, JSON} ->
            % Log an error with the payment
            m_payment_log:log(
                PaymentId,
                <<"ERROR">>,
                [
                    {psp_module, mod_payment_mollie},
                    {description, <<"API Unexpected result fetching mandates from Mollie">>},
                    {request_result, JSON}
                ],
                Context),
            lager:error("API unexpected result fetching mollie mandates for payment ~p (user ~p): ~p",
                        [ PaymentId, UserId, JSON ]),
            {error, unexpected_result};
        {error, Reason} = Error ->
            % Log an error with the payment
            m_payment_log:log(
                PaymentId,
                <<"ERROR">>,
                [
                    {psp_module, mod_payment_mollie},
                    {description, <<"API Error fetching mandates from Mollie">>},
                    {request_result, Error}
                ],
                Context),
            lager:error("API error creating mollie subscription for payment ~p (user ~p): ~p",
                        [ PaymentId, UserId, Reason ]),
            Error
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
    case api_call(get, "customers/" ++ z_convert:to_list(CustId) ++ "/subscriptions?limit=250", [], Context) of
        {ok, #{ <<"_embedded">> := #{ <<"subscriptions">> := Data } } = Result} ->
            Links = maps:get(<<"_links">>, Result, #{}),
            case mollie_list_subscriptions_next(Links, Context) of
                {ok, NextData} ->
                    {ok, Data ++ NextData};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

mollie_list_subscriptions_next(#{ <<"next">> := #{ <<"href">> := Next } }, Context) when is_binary(Next), Next =/= <<>> ->
    case api_call(get, Next, [], Context) of
        {ok, #{ <<"_embedded">> := #{ <<"subscriptions">> := Data }, <<"_links">> := Links }} ->
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
        <<"amount">> := #{
            <<"currency">> := Currency,
            <<"value">> := Amount
        },
        <<"interval">> := Interval,
        <<"description">> := Description
    } = Sub) ->
    Cancelled = maps:get(<<"canceledAt">>, Sub, undefined),
    #{
        id => {mollie_subscription, CustId, SubId},
        is_valid => is_null(Cancelled),
        start_date => to_date(Start),
        end_date => to_date(Cancelled),
        description => Description,
        interval => Interval,
        amount => z_convert:to_float(Amount),
        currency => Currency
    }.

is_null(undefined) -> true;
is_null(null) -> true;
is_null(<<>>) -> true;
is_null(_) -> false.

to_date(undefined) -> undefined;
to_date(null) -> undefined;
to_date(<<>>) -> undefined;
to_date(D) -> z_datetime:to_datetime(D).


has_subscription(UserId, Context) ->
    case list_subscriptions(UserId, Context) of
        {ok, Subs} ->
            lists:any(fun is_subscription_active/1, Subs);
        {error, _} ->
            false
    end.

is_subscription_active(#{ end_date := undefined }) -> true;
is_subscription_active(#{ end_date := _}) -> false.


cancel_subscription({mollie_subscription, CustId, SubId}, Context) ->
    case api_call(delete, "customers/" ++
                      z_convert:to_list(CustId) ++
                      "/subscriptions/" ++
                      z_convert:to_list(SubId),
                  [], Context) of
        {ok, _} ->
            lager:info("Cancelled mollie subscription for #~p", [CustId]),
            ok;
        {error, 410} ->
            lager:info("API error cancelling mollie subscription for #~p: ~p (already canceled)", [CustId, 410]),
            ok;
        {error, 422} ->
            lager:info("API error cancelling mollie subscription for #~p: ~p (already canceled?)", [CustId, 422]),
            ok;
        {error, Reason} = Error ->
            lager:error("API error cancelling mollie subscription for #~p: ~p", [CustId, Reason]),
            Error
    end;
cancel_subscription(UserId, Context) when is_integer(UserId) ->
    case list_subscriptions(UserId, Context) of
        {ok, Subs} ->
            lists:foldl(
                fun
                    (#{ id := SubId, end_date := undefined }, ok) ->
                        cancel_subscription(SubId, Context);
                    (#{ id := _SubId, end_date := {_, _} }, ok) ->
                        ok;
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
                    Args = customer_args(UserId, Context),
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

%% @doc Update the customer information at Mollie for a given user.
-spec customer_sync(UserId, Context) -> ok | {error, Reason} when
    UserId :: m_rsc:resource_id(),
    Context :: z:context(),
    Reason :: enoent | term().
customer_sync(UserId, Context) ->
    case mollie_customer_id(UserId, false, Context) of
        {ok, CustId} ->
            Args = customer_args(UserId, Context),
            case api_call(patch, "customers/" ++ z_convert:to_list(CustId), Args, Context) of
                {ok, _Json} ->
                    lager:info("Synced user ~p to mollie customer \"~s\" (~p)",
                               [UserId, CustId, Args]),
                    ok;
                {error, Reason} = Error ->
                    lager:info("Could not sync user ~p to mollie customer \"~s\" (~p): ~p",
                               [UserId, CustId, Args, Reason]),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

customer_args(UserId, Context) ->
    ContextSudo = z_acl:sudo(Context),
    Email = m_rsc:p_no_acl(UserId, email_raw, Context),
    {Name, _Context} = z_template:render_to_iolist("_name.tpl", [ {id, UserId} ], ContextSudo),
    [
        {name, z_string:trim(z_html:unescape(iolist_to_binary(Name)))},
        {email, Email}
    ].

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
                            RecType = sequenceType(PspData),
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

sequenceType(#{ <<"sequenceType">> := SequenceType }) -> SequenceType;  % v2 API
sequenceType(#{ <<"recurringType">> := SequenceType }) -> SequenceType; % v1 API
sequenceType(_) -> <<>>.


