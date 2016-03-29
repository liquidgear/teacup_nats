% Copyright (c) 2016, Yuce Tekol <yucetekol@gmail.com>.
% All rights reserved.
%
% Redistribution and use in source and binary forms, with or without
% modification, are permitted provided that the following conditions are
% met:
%
% * Redistributions of source code must retain the above copyright
%   notice, this list of conditions and the following disclaimer.
%
% * Redistributions in binary form must reproduce the above copyright
%   notice, this list of conditions and the following disclaimer in the
%   documentation and/or other materials provided with the distribution.
%
% * The names of its contributors may not be used to endorse or promote
%   products derived from this software without specific prior written
%   permission.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
% A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
% OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
% LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
% DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
% THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
% OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-module(nats@teacup).
-behaviour(teacup_server).

-export([teacup@signature/1,
         teacup@init/1,
         teacup@status/2,
         teacup@data/2,
         teacup@error/2,
         teacup@call/3,
         teacup@cast/2,
         teacup@info/2]).


-include("teacup_nats_common.hrl").

-define(MSG, ?MODULE).
-define(VERSION, <<"0.3.1">>).
-define(PUBLISH_TIMEOUT, 10).

%% == Callbacks

teacup@signature(#{verbose := true}) ->
    {ok, ?VERBOSE_SIGNATURE};

teacup@signature(_) ->
    {ok, ?SIGNATURE}.

teacup@init(Opts) ->
    NewOpts = maps:merge(default_opts(), Opts),
    {ok, NewOpts#{ready => false,
                  from => undefined}}.

teacup@status(connect, State) ->
    nats_msg:init(),
    NewState = State#{data_acc => <<>>,
                      server_info => #{},
                      next_sid => 0,
                      sid_to_key => #{},
                      key_to_sid => #{},
                      ready => false,
                      pub_batch => [],
                      pub_timer => undefined},
    notify_parent({status, connect}, State),
    {noreply, NewState};

teacup@status({disconnect, _}, State) ->
    notify_parent({status, disconnect}, State),
    {stop, normal, State};

teacup@status(Status, State) ->
    notify_parent({status, Status}, State).

teacup@data(Data, #{data_acc := DataAcc} = State) ->
    NewData = <<DataAcc/binary, Data/binary>>,
    {Messages, Remaining} = nats_msg:decode_all(NewData),
    case interp_messages(Messages, State) of
        {noreply, NewState} ->
            {noreply, NewState#{data_acc => Remaining}};
        Other ->
            Other
    end.

teacup@error(Reason, State) ->
    notify_parent({error, Reason}, State),
    {stop, Reason, State}.

teacup@call({connect, Host, Port}, From, State) ->
    NewState = do_connect(Host, Port, State#{from => From}),
    {noreply, NewState};

teacup@call({pub, Subject, Opts}, From, State) ->
    NewState = do_pub(Subject, Opts, State#{from := From}),
    {noreply, NewState};

teacup@call({sub, Subject, Opts, Pid}, From, State) ->
    NewState = do_sub(Subject, Opts, Pid, State#{from := From}),
    {noreply, NewState};

teacup@call({unsub, Subject, Opts, Pid}, From, State) ->
    NewState = do_unsub(Subject, Opts, Pid, State#{from := From}),
    {noreply, NewState}.

teacup@cast({connect, Host, Port}, State) ->
    NewState = do_connect(Host, Port, State),
    {noreply, NewState};

teacup@cast(ping, #{ready := true} = State) ->
    teacup_server:send(self(), nats_msg:ping()),
    {noreply, State};

teacup@cast({pub, Subject, Opts},
            #{ready := true} = State) ->
    NewState = do_pub(Subject, Opts, State),
    {noreply, NewState};

teacup@cast({pub_batch, Batch},
            #{ready := true} = State) ->
    NewState = do_pub_batch(Batch, State),
    {noreply, NewState};

teacup@cast({sub, Subject, Opts, Pid}, State) ->
    NewState = do_sub(Subject, Opts, Pid, State),
    {noreply, NewState};

teacup@cast({unsub, Subject, Opts, Pid}, State) ->
    NewState = do_unsub(Subject, Opts, Pid, State),
    {noreply, NewState}.

teacup@info(ready, #{ready := false,
                     from := undefined} = State) ->
    notify_parent(ready, State),
    {noreply, State#{ready => true}};

teacup@info(ready, State) ->
    % Ignore other ready messages
    {noreply, State};

teacup@info(publish_timeout, #{pub_batch := PubBatch} = State) ->
    PubTimer = case PubBatch of
        [] ->
            undefined;
        _ ->
            teacup_server:send(self(), lists:reverse(PubBatch)),
            erlang:send_after(?PUBLISH_TIMEOUT, self(), publish_timeout)
    end,
    {noreply, State#{pub_batch => [],
                     pub_timer => PubTimer}}.

%% == Internal

default_opts() ->
    #{verbose => false,
      pedantic => false,
      ssl_required => false,
      auth_token => undefined,
      user => undefined,
      pass => undefined,
      name => <<"teacup_nats">>,
      lang => <<"erlang">>,
      version => ?VERSION}.

interp_messages(Messages, State) ->
    F = fun(M, {Rs, S}) ->
        case interp_message(M, S) of
            {[], NS} -> {Rs, NS}
            % {NR, NS} -> {[NR|Rs], NS}
        end
    end,
    try lists:foldl(F, {[], State}, Messages) of
        {Response, NewState} ->
            case Response of
                [] -> ok;
                _ -> teacup_server:send(self(), lists:reverse(Response))
            end,
            {noreply, NewState}
    catch
        throw:disconnect ->
            {stop, normal, State}
    end.

interp_message([], State) ->
    {[], State};

interp_message(ping, State) ->
    % Send pong messages immediately
    teacup_server:send(self(), nats_msg:pong()),
    {[], State};

interp_message(pong, State) ->
    % TODO: reset ping timer
    {[], State};

interp_message({info, BinInfo}, #{from := From} = State) ->
    % Send connect messages immediately
    Info = jsx:decode(BinInfo, [return_maps]),
    NewState = State#{server_info => Info},
    teacup_server:send(self(), client_info(NewState)),
    case From of
        undefined -> self() ! ready;
        _ -> ok
    end,
    {[], NewState};

interp_message({msg, {Subject, Sid, ReplyTo, Payload}},
               #{ref@ := Ref,
                 sid_to_key := SidToKey} = State) ->
    case maps:get(Sid, SidToKey, undefined) of
        undefined -> ok;
        {_, Pid} ->
            Resp = {msg, Subject, ReplyTo, Payload},
            Pid ! {Ref, Resp}
    end,
    {[], State};

interp_message(ok, #{from := From} = State)
        when From /= undefined ->
    gen_server:reply(From, ok),
    {[], State#{from => undefined,
                ready => true}};

interp_message({error, Reason}, #{from := From} = State)
        when From /= undefined ->
    gen_server:reply(From, {error, Reason}),
    {[], State#{from => undefined}};

interp_message({error, Reason} = Error, State) ->
    notify_parent(Error, State),
    case error_disconnect(Reason) of
        true -> throw(disconnect);
        _ -> {[], State}
    end.

error_disconnect(invalid_subject) -> false;
error_disconnect(_) -> true.

client_info(#{server_info := ServerInfo} = State) ->
    % Include user and name iff the server requires it
    FieldsList = [verbose, pedantic, ssl_required, auth_token, name, lang, version],
    NewFieldsList = case maps:get(<<"auth_required">>, ServerInfo, false) of
        true -> [user, pass | FieldsList];
        _ -> FieldsList
    end,
    Nats = maps:with(NewFieldsList, State),
    nats_msg:connect(jsx:encode(Nats)).

notify_parent(What, #{parent@ := Parent,
                      ref@ := Ref}) ->
    Parent ! {Ref, What}.

do_connect(Host, Port, #{ref@ := Ref} = State) ->
    teacup:connect(Ref, Host, Port),
    State.

do_pub(Subject, Opts, #{pub_batch := PubBatch,
                        pub_timer := PubTimer} = State) ->
    ReplyTo = maps:get(reply_to, Opts, undefined),
    Payload = maps:get(payload, Opts, <<>>),
    BinMsg = nats_msg:pub(Subject, ReplyTo, Payload),
    NewState = State#{pub_batch => [BinMsg | PubBatch]},
    case PubTimer of
        undefined ->
            NewPubTimer = erlang:send_after(?PUBLISH_TIMEOUT,
                                            self(),
                                            publish_timeout),
            NewState#{pub_timer => NewPubTimer};
        _ ->
            NewState
    end.

do_pub_batch(Batch, State) ->
    F = fun({Subject, Opts}) ->
        ReplyTo = maps:get(reply_to, Opts, undefined),
        Payload = maps:get(payload, Opts, <<>>),
        nats_msg:pub(Subject, ReplyTo, Payload)
    end,
    BinBatch = lists:map(F, Batch),
    teacup_server:send(self(), BinBatch),
    State.

do_sub(Subject, Opts, Pid, #{next_sid := DefaultSid,
                             sid_to_key := SidToKey,
                             key_to_sid := KeyToSid,
                             ready := true} = State) ->
    K = {Subject, Pid},
    Sid = maps:get(K, KeyToSid, integer_to_binary(DefaultSid)),
    NewKeyToSid = maps:put(K, Sid, KeyToSid),
    NewSidToKey = maps:put(Sid, K, SidToKey),
    QueueGrp = maps:get(queue_group, Opts, undefined),
    BinMsg = nats_msg:sub(Subject, QueueGrp, Sid),
    teacup_server:send(self(), BinMsg),
    State#{next_sid => DefaultSid + 1,
           sid_to_key => NewSidToKey,
           key_to_sid => NewKeyToSid}.

do_unsub(Subject, Opts, Pid, #{key_to_sid := KeyToSid,
                               ready := true} = State) ->
    % Should we crash if Sid for Pid not found?
    Sid = maps:get({Subject, Pid}, KeyToSid, undefined),
    case Sid of
        undefined ->
            ok;
        _ ->
            MaxMsgs = maps:get(max_messages, Opts, undefined),
            BinMsg = nats_msg:unsub(Sid, MaxMsgs),
            teacup_server:send(self(), BinMsg)
    end,
    State.