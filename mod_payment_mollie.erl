%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2018-2021 Driebit BV
%% @doc Payment PSP module for Mollie

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

-module(mod_payment_mollie).

-mod_title("Payments using Mollie").
-mod_description("Payments using Payment Service Provider Mollie").
-mod_author("Driebit").
-mod_depends([ mod_payment ]).

-export([
    observe_payment_psp_request/2,
    observe_payment_psp_view_url/2,
    observe_payment_psp_status_sync/2,
    observe_cancel_recurring_psp_request/2,
    observe_tick_24h/2
]).

-include_lib("mod_payment/include/payment.hrl").

%% @doc Payment request, make new payment with Mollie, return
%%      payment (mollie) details and a redirect uri for the user
%%      to handle the payment.
observe_payment_psp_request(#payment_psp_request{ payment_id = PaymentId, currency = <<"EUR">> }, Context) ->
    m_payment_mollie_api:create(PaymentId, Context);
observe_payment_psp_request(#payment_psp_request{}, _Context) ->
    undefined.

observe_payment_psp_view_url(#payment_psp_view_url{ psp_module = ?MODULE, psp_external_id = MollieId }, _Context) ->
    {ok, m_payment_mollie_api:payment_url(MollieId)};
observe_payment_psp_view_url(#payment_psp_view_url{}, _Context) ->
    undefined.

%% @doc Used to fetch the status of all payments in a non-final state. Called manually or periodically.
observe_payment_psp_status_sync(#payment_psp_status_sync{
        payment_id = PaymentId,
        psp_module = ?MODULE,
        psp_external_id = TransactionId
    }, Context) ->
    m_payment_mollie_api:payment_sync(PaymentId, TransactionId, Context);
observe_payment_psp_status_sync(#payment_psp_status_sync{}, _Context) ->
    undefined.

%% @doc Cancel the subscription at Mollie
observe_cancel_recurring_psp_request(#cancel_recurring_psp_request{ user_id = UserId }, Context) ->
    m_payment_mollie_api:cancel_subscription(UserId, Context).


%% @doc Periodic poll for recurring payments. The recurring payments could be missed because
%% they are newly created by the PSP and then pushed to the webhook.
%% Non-recurring payments are synced using the psp_status_sync.
observe_tick_24h(tick_24h, Context) ->
    m_payment_mollie_api:payment_sync_recurrent(Context).
