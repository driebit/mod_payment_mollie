%% @copyright 2018 Driebit BV
%% @doc Webhook for callbacks by Mollie.

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

-module(controller_mollie_webhook).

-export([
    init/1,
    service_available/2,
    allowed_methods/2,
    process_post/2
]).

-include_lib("controller_webmachine_helper.hrl").
-include_lib("zotonic.hrl").

init(DispatchArgs) -> {ok, DispatchArgs}.

service_available(ReqData, DispatchArgs) when is_list(DispatchArgs) ->
    Context  = z_context:new(ReqData, ?MODULE),
    Context1 = z_context:set(DispatchArgs, Context),
    ?WM_REPLY(true, Context1).

allowed_methods(ReqData, Context) ->
    Context0 = ?WM_REQ(ReqData, Context),
    Context1 = z_context:ensure_qs(Context0),
    ?WM_REPLY(['POST'], Context1).

process_post(ReqData, Context) ->
    Context1 = ?WM_REQ(ReqData, Context),
    ExtPaymentId = z_convert:to_binary(z_context:get_q(id, Context1)),
    FirstPaymentNr = z_convert:to_binary(z_context:get_q(payment_nr, Context1)),
    case m_payment_mollie_api:payment_sync_webhook(FirstPaymentNr, ExtPaymentId, Context1) of
        ok ->
            ?WM_REPLY(true, Context1);
        {error, notfound} ->
            ?WM_REPLY({halt, 404}, Context1);
        {error, _} ->
            ?WM_REPLY({halt, 500}, Context1)
    end.
