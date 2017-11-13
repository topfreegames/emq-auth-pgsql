%%--------------------------------------------------------------------
%% Copyright (c) 2013-2017 EMQ Enterprise, Inc. (http://emqtt.io)
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
%%--------------------------------------------------------------------

-module(emq_auth_pgsql).

-behaviour(emqttd_auth_mod).

-include("emq_auth_pgsql.hrl").

-include_lib("emqttd/include/emqttd.hrl").

-export([init/1, check/3, description/0]).

-record(state, {auth_query, super_query, hash_type}).

-define(UNDEFINED(S), (S =:= undefined orelse S =:= <<>>)).

%%--------------------------------------------------------------------
%% Auth Module Callbacks
%%--------------------------------------------------------------------

init({AuthQuery, SuperQuery, HashType}) ->
    {ok, #state{auth_query = AuthQuery, super_query = SuperQuery, hash_type = HashType}}.

check(#mqtt_client{username = Username}, Password, _State) when ?UNDEFINED(Username); ?UNDEFINED(Password) ->
    {error, username_or_password_undefined};

check(Client, Password, #state{auth_query  = {AuthSql, AuthParams},
                               super_query = SuperQuery,
                               hash_type   = HashType}) ->
    case emq_auth_pgsql_cli:equery(AuthSql, AuthParams, Client) of
        {ok, _, [Record]} ->
            case check_pass(Record, Password, HashType) of
                ok -> {ok, is_superuser(SuperQuery, Client)};
                Error -> Error
            end;
         {ok, _, []} ->
            ignore;
         {error, Reason} ->
            {error, Reason}
     end.

check_pass({PassHash}, Password, HashType) ->
    check_pass(PassHash, hash(HashType, Password));
check_pass({PassHash, Salt}, Password, {pbkdf2, Macfun, Iterations, Dklen}) ->
    check_pass(PassHash, hash(pbkdf2, {Salt, Password, Macfun, Iterations, Dklen}));
check_pass({PassHash, Salt}, Password, {salt, bcrypt}) ->
    check_pass(PassHash, hash(bcrypt, {Salt, Password}));
check_pass({PassHash, Salt}, Password, {salt, HashType}) ->
    check_pass(PassHash, hash(HashType, <<Salt/binary, Password/binary>>));
check_pass({PassHash, Salt}, Password, {HashType, salt}) ->
    check_pass(PassHash, hash(HashType, <<Password/binary, Salt/binary>>)).

check_pass(PassHash, PassHash) -> ok;
check_pass(_, _)               -> {error, password_error}. 

hash(Type, Password) ->
    passwd_hash(Type, Password).

passwd_hash(pbkdf2, {Salt, Password, Macfun, Iterations, Dklen}) ->
	case pbkdf2:pbkdf2(Macfun, Password, Salt, Iterations, Dklen) of
		 {ok, Hexstring} -> string:slice(base64:encode(Hexstring), 0, 32);
		 {error, Error} -> lager:error("PasswdHash with pbkdf2 error:~p", [Error]), <<>>
	end;

description() -> "Custom Authentication with PostgreSQL".

%%--------------------------------------------------------------------
%% Is Superuser?
%%--------------------------------------------------------------------

-spec(is_superuser(undefined | {string(), list()}, mqtt_client()) -> boolean()).
is_superuser(undefined, _Client) ->
    false;
is_superuser({SuperSql, Params}, Client) ->
    case emq_auth_pgsql_cli:equery(SuperSql, Params, Client) of
        {ok, [_Super], [{true}]} ->
            true;
        {ok, [_Super], [_False]} ->
            false;
        {ok, [_Super], []} ->
            false;
        {error, _Error} ->
            false
    end.

