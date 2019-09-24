%% @copyright 2018 Driebit BV
%% @doc API interface for Mollie PSP

%% Copyright 2018 Driebit BV
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
    pull_status/2,

    is_test/1,
    api_key/1,
    webhook_url/2,
    payment_url/1,
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
            Customer =
                case proplists:get_value(user_id, Payment) of
                    undefined ->
                        [];
                    UserId ->
                        {ok, CustomerId} = create_customer(UserId, Context),
                        {ok, _} = m_rsc:update(UserId, [{mollie_customer_id, CustomerId}], z_acl:sudo(Context)),
                        [{customerId, CustomerId}]
                end,
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
            ]
                ++ Recurring
                ++ Customer,
            case api_call(post, "payments", Args, Context) of
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
                      "ERROR",
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
        Currency ->
            lager:error("Mollie payment request with non EUR currency: ~p", [Currency]),
            {error, {currency, only_eur}}
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


%% @doc Pull the payment status from Mollie, as a response to a webhook call
-spec pull_status(binary(), z:context()) -> ok | {error, notfound|term()}.
pull_status(ExtId, Context) ->
    case m_payment:get_by_psp(mod_payment_mollie, ExtId, Context) of
        {ok, Payment} ->
            % Fetch the status from Mollie
            PaymentId = proplists:get_value(id, Payment),
            lager:info("Payment PSP Mollie webhook call for payment #~p", [PaymentId]),
            case api_call(get, "payments/" ++ z_convert:to_list(ExtId), [], Context) of
                {ok, JSON} ->
                    Status = maps:get(<<"status">>, JSON),
                    lager:info("Payment PSP Mollie got status ~p for payment #~p",
                               [Status, PaymentId]),
                    % UPDATE OUR ORDER STATUS
                    update_payment_status(PaymentId, Status, Context),
                    case proplists:get_value(recurring, Payment) of
                        true ->
                            create_subscription(Payment, Context);
                        false ->
                            ok
                    end;
                {error, Error} ->
                    %% Log an error with the payment
                    m_payment_log:log(
                      PaymentId,
                      "ERROR",
                      [
                       {psp_module, mod_payment_mollie},
                       {description, "API Error fetching status from Mollie"},
                       {request_result, Error}
                      ],
                      Context),
                    lager:error("API error creating mollie payment for #~p: ~p", [PaymentId, Error]),
                    Error
            end;
        {error, notfound} ->
            lager:error("Payment PSP Mollie webhook call with unknown id ~p", [ExtId]),
            {error, notfound};
        {error, _} = Error ->
            lager:error("Payment PSP Mollie webhook call with id ~p, fetching payment error: ~p", [ExtId, Error]),
            Error
    end.

% Status is one of: open cancelled expired failed pending paid paidout refunded charged_back
update_payment_status(PaymentId, <<"open">>, Context) ->         mod_payment:set_payment_status(PaymentId, new, Context);
update_payment_status(PaymentId, <<"cancelled">>, Context) ->    mod_payment:set_payment_status(PaymentId, cancelled, Context);
update_payment_status(PaymentId, <<"expired">>, Context) ->      mod_payment:set_payment_status(PaymentId, failed, Context);
update_payment_status(PaymentId, <<"failed">>, Context) ->       mod_payment:set_payment_status(PaymentId, failed, Context);
update_payment_status(PaymentId, <<"pending">>, Context) ->      mod_payment:set_payment_status(PaymentId, pending, Context);
update_payment_status(PaymentId, <<"paid">>, Context) ->         mod_payment:set_payment_status(PaymentId, paid, Context);
update_payment_status(PaymentId, <<"paidout">>, Context) ->      mod_payment:set_payment_status(PaymentId, paid, Context);
update_payment_status(PaymentId, <<"refunded">>, Context) ->     mod_payment:set_payment_status(PaymentId, refunded, Context);
update_payment_status(PaymentId, <<"charged_back">>, Context) -> mod_payment:set_payment_status(PaymentId, refunded, Context);
update_payment_status(_PaymentId, _Status, _Context) -> ok.

api_call(Method, Endpoint, Args, Context) ->
    case api_key(Context) of
        {ok, ApiKey} ->
            Url = ?MOLLIE_API_URL ++ z_convert:to_list(Endpoint),
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
            lager:info("Making API call to Mollie: ~p~n", [Request]),
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
                    lager:error("Mollie returns ~p: ~p ~p", [ Code, Payload, Headers]),
                    {error, Code};
                {error, _} = Error ->
                    Error
            end;
        {error, notfound} ->
            {error, api_key_not_set}
    end.




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

create_customer(UserId, Context) ->
    case m_rsc:exists(UserId, Context) of
        true ->
            Email = m_rsc:p(UserId, email, z_acl:sudo(Context)),
            Name = z_trans:lookup_fallback(m_rsc:p(UserId, title, z_acl:sudo(Context)), Context),
            Args = [{name, Name}, {email, Email}],
            case api_call(post, "customers", Args, Context) of
                {ok, Json} ->
                    {ok, maps:get(<<"id">>, Json)};
                Other ->
                    Other
            end;
        false ->
            {error, resource_does_not_exist}
    end.

valid_mandate(Mandate) ->
    case maps:get(<<"status">>, Mandate) of
        <<"pending">> ->
            true;
        <<"valid">> ->
            true;
        _ ->
            false
    end.

create_subscription(Payment, Context) ->
    UserId = proplists:get_value(user_id, Payment),
    CustomerId = z_convert:to_binary(m_rsc:p(UserId, mollie_customer_id, z_acl:sudo(Context))),
    Email = m_rsc:p(UserId, email, z_acl:sudo(Context)),
    WebhookUrl = webhook_url(proplists:get_value(payment_nr, Payment), Context),
    case api_call(get, "customers/" ++ z_convert:to_list(CustomerId) ++ "/mandates",
                   [], Context) of
        {ok, Response} ->
            Mandates = maps:get(<<"data">>, Response, []),
            case lists:filter(fun valid_mandate/1, Mandates) of
                [] ->
                    ok;
                _ ->
                    {{Year, Month, Day}, _} = calendar:local_time(),
                    YearFromNow = io_lib:format("~4..0w-~2..0w-~2..0w", [Year + 1, Month, Day]),
                    Args =
                        [{amount, proplists:get_value(amount, Payment)},
                         {interval, <<"12 months">>},
                         {startDate, list_to_binary(YearFromNow)},
                         {webhookUrl, WebhookUrl},
                         {description, <<"Subscription for ", Email/binary, " - ", CustomerId/binary>>}],
                    {ok, Response2} =
                        api_call(post, "customers/" ++ z_convert:to_list(CustomerId) ++ "/subscriptions",
                                 Args, Context),
                    SubscriptionId = maps:get(<<"id">>, Response2),
                    {ok, _} = m_rsc:update(UserId, [{mollie_subscription_id, SubscriptionId}], z_acl:sudo(Context)),
                    ok
            end;
        {error, _} = Error ->
            %% Log an error with the payment
            m_payment_log:log(
              CustomerId,
              "ERROR",
              [
               {psp_module, mod_payment_mollie},
               {description, "API Error fetching status from Mollie"},
               {request_result, Error}
              ],
              Context),
            lager:error("API error creating mollie subscription for #~p: ~p", [CustomerId, Error]),
            Error
    end.

has_subscription(UserId, Context) ->
    CustomerId = m_rsc:p(UserId, mollie_customer_id, z_acl:sudo(Context)),
    case m_rsc:p(UserId, mollie_subscription_id, z_acl:sudo(Context)) of
        undefined ->
            false;
        SubscriptionId ->
        case api_call(get, "customers/" ++
                          z_convert:to_list(CustomerId) ++
                          "/subscriptions/" ++
                          z_convert:to_list(SubscriptionId),
                      [], Context) of
            {ok, {{_, 410, _}, _, _}} ->
                false;
            {ok, {{_, 404, _}, _, _}} ->
                false;
            {ok, Response} ->
                Status = maps:get(<<"status">>, Response),
                Status == <<"active">>;
            {error, Error} ->
                m_payment_log:log(
                  CustomerId,
                  "ERROR",
                  [
                   {psp_module, mod_payment_mollie},
                   {description, "API Error fetching subscription info from Mollie"},
                   {request_result, Error}
                  ],
                  Context),
                lager:error("API error fetching mollie subscription for #~p: ~p", [CustomerId, Error]),
                false
        end
    end.


cancel_subscription(UserId, Context) ->
    CustomerId = m_rsc:p(UserId, mollie_customer_id, z_acl:sudo(Context)),
    SubscriptionId = m_rsc:p(UserId, mollie_subscription_id, z_acl:sudo(Context)),
    case api_call(delete, "customers/" ++
                      z_convert:to_list(CustomerId) ++
                      "/subscriptions/" ++
                      z_convert:to_list(SubscriptionId),
                  [], Context) of
        {ok, _} ->
            ok;
        {error, Error} ->
            m_payment_log:log(
              CustomerId,
              "ERROR",
              [
               {psp_module, mod_payment_mollie},
               {description, "API Error cancelling subscription from Mollie"},
               {request_result, Error}
              ],
              Context),
            lager:error("API error cancelling mollie subscription for #~p: ~p", [CustomerId, Error]),
            Error
    end.
