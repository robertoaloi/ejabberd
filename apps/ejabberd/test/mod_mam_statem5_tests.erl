%% @doc This module ensures, that there are no crashes because of inconsistency.
-module(mod_mam_statem5_tests).
-include_lib("ejabberd/include/jlib.hrl").

-ifdef(TEST).
-ifdef(PROPER).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-behaviour(proper_statem).

%% Behaviour callbacks
-export([initial_state/0, command/1,
         precondition/2, postcondition/3, next_state/3]).

-import(mod_mam_utils, [
    microseconds_to_datetime/1
]).

-record(state, {
    next_mess_id,
    next_now, % microseconds
    mess_ids
}).
-define(M, mod_mam_riak_arch).

%% ------------------------------------------------------------------
%% Type Generators
%% ------------------------------------------------------------------

packet() ->
    <<"hi">>.

alice() ->
    #jid{luser = <<"alice">>, lserver = <<"wonderland">>, lresource = <<>>,
          user = <<"alice">>,  server = <<"wonderland">>,  resource = <<>>}.

cat() ->
    #jid{luser = <<"cat">>, lserver = <<"wonderland">>, lresource = <<>>,
          user = <<"cat">>,  server = <<"wonderland">>,  resource = <<>>}.

cat1() ->
    #jid{luser = <<"cat">>, lserver = <<"wonderland">>, lresource = <<"1">>,
          user = <<"cat">>,  server = <<"wonderland">>,  resource = <<"1">>}.

user_jid() ->
    oneof([cat(), cat1()]).

maybe_user_jid() ->
    oneof([undefined, user_jid()]).

jid_pair() ->
    {alice(), user_jid()}.


init_now() ->
%   mod_mam_utils:datetime_to_microseconds({{2000,1,1}, {0,0,0}}).
    946684800000000.

microseconds_to_mess_id(Microseconds) when is_integer(Microseconds) ->
    Microseconds * 256.

next_now(S=#state{next_now=PrevNow}) ->
    set_next_now(PrevNow + random_microsecond_delay(), S).

%% @doc This function is called each time, when new time is needed.
set_next_now(NextNow, S=#state{}) when is_integer(NextNow) ->
    ?M:set_now(NextNow),
    S#state{
        next_now=NextNow,
        next_mess_id=microseconds_to_mess_id(NextNow)}.

random_microsecond_delay() ->
    %% One hour is the maximim delay.
    random:uniform(3600000000).

page_size() -> integer(0, 5).

offset() -> integer(0, 10).

mess_id(#state{next_mess_id=MessID, mess_ids=MessIDs}) ->
    oneof([MessID|MessIDs]).

rsm(MessID) ->
    oneof([
        undefined,
        #rsm_in{index=offset()},
        #rsm_in{direction = before},
        #rsm_in{direction = oneof([before, aft]), id = MessID}
    ]).

%% ------------------------------------------------------------------
%% Callbacks
%% ------------------------------------------------------------------

initial_state() -> 
    set_next_now(init_now(), #state{mess_ids=[]}).

command(S) ->
    oneof([
     ?LET({LocJID, RemJID}, jid_pair(),
          {call, ?M, archive_message,
           [S#state.next_mess_id, incoming, LocJID, RemJID, RemJID, packet()]}),
     ?LET({LocJID, RemJID}, jid_pair(),
          {call, ?M, archive_message,
           [S#state.next_mess_id, outgoing, LocJID, RemJID, LocJID, packet()]}),
    {call, ?M, lookup_messages,
     [alice(), rsm(mess_id(S)), undefined, undefined,
      S#state.next_now, maybe_user_jid(), page_size(), true, 256]}] ++
    case S#state.mess_ids of [] -> []; MessIDs -> [
        {call, ?M, dirty_purge_single_message,
            [alice(), oneof(MessIDs), S#state.next_now]}
    ]
    end).

precondition(_S, _C) ->
    true.

postcondition(_S, _C, _R) ->
    true.

next_state(S, _V, {call, ?M, archive_message,
                   [MessID, _, _, _, _, _]}) ->
    next_now(S#state{
        mess_ids=[MessID|S#state.mess_ids]});
next_state(S, _V, _C) ->
    S.

%% ------------------------------------------------------------------
%% Model helpers
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% Service Code
%% ------------------------------------------------------------------

prop_main() ->
    ?FORALL(Cmds, commands(?MODULE),
       ?TRAPEXIT(
            begin
            ?M:reset_mock(),
            {History,State,Result} = run_commands(?MODULE, Cmds),
            ?WHENFAIL(begin
                io:format("History: ~p\nState: ~p\nResult: ~p\n",
                          [History, State, Result])
                end,
              aggregate(command_names(Cmds), Result =:= ok))
            end)).
       

run_property_testing_test_() ->
    {setup,
     fun() -> ?M:load_mock(0) end,
     fun(_) -> ?M:unload_mock() end,
     {timeout, 60,
         fun() ->
            EunitLeader = erlang:group_leader(),
            erlang:group_leader(whereis(user), self()),
            Res = proper:module(?MODULE,
                [{numtests, 300}, {max_size, 50}, long_result]),
            erlang:group_leader(EunitLeader, self()),
            analyse_result(Res),
            ?assertEqual([], Res)
         end}}.

analyse_result([{{?MODULE,prop_main,0}, [Cmds|_]}|T]) ->
    analyse_bad_commands(Cmds),
    analyse_result(T);
analyse_result([_|T]) ->
    analyse_result(T);
analyse_result([]) ->
    [].

analyse_bad_commands(Cmds) ->
    ?M:reset_mock(),
    {History,State,Result} = run_commands(?MODULE, Cmds),
    io:format(user, "~n~p~n", [Cmds]),
    io:format(user, "~n~sok.~2n", [pretty_print_result(Cmds)]),
    ok.

pretty_print_result([{set, _,
    {call, _, archive_message,
     [MessID, Dir, LocJID, RemJID, SrcJID, _]}}|T]) ->
    [pretty_print_archive_message(MessID, Dir, LocJID, RemJID, SrcJID)
    |pretty_print_result(T)];
pretty_print_result([{set, _,
    {call, _, lookup_messages,
     [LocJID, RSM, _, _, Now, _, PageSize, _, _]}}|T]) ->
    [pretty_print_lookup_messages(LocJID, RSM, Now, PageSize)
    |pretty_print_result(T)];
pretty_print_result([{set, _,
    {call, ?M, dirty_purge_single_message, [LocJID, MessID, Now]}}|T]) ->
    [pretty_print_dirty_purge_single_message(LocJID, MessID, Now)
    |pretty_print_result(T)];
pretty_print_result([_|T]) ->
    ["% skipped\n"|pretty_print_result(T)];
pretty_print_result([]) ->
    [].

pretty_print_archive_message(MessID, Dir, LocJID, RemJID, SrcJID) ->
    {Now, _} = mod_mam_utils:decode_compact_uuid(MessID),
    DateTime = microseconds_to_datetime(Now),
    io_lib:format(
        "set_now(datetime_to_microseconds(~p)),~n"
        "archive_message(id(), ~p, ~s, ~s, ~s, packet()),~n",
        [DateTime, Dir,
         pretty_print_jid(LocJID),
         pretty_print_jid(RemJID),
         pretty_print_jid(SrcJID)]).

pretty_print_lookup_messages(LocJID, RSM, Now, PageSize) ->
    DateTime = microseconds_to_datetime(Now),
    io_lib:format(
        "set_now(datetime_to_microseconds(~p)),~n"
        "lookup_messages(~s, ~s, undefined, undefined, "
        "get_now(), undefined, ~p, true, 256),~n",
        [DateTime,
         pretty_print_jid(LocJID),
         pretty_print_rsm(RSM),
         PageSize]).

pretty_print_dirty_purge_single_message(LocJID, MessID, Now) ->
    DateTime = microseconds_to_datetime(Now),
    {MessMicroseconds, _} = mod_mam_utils:decode_compact_uuid(MessID),
    MessDateTime = microseconds_to_datetime(MessMicroseconds),
    io_lib:format(
        "set_now(datetime_to_microseconds(~p)),~n"
        "dirty_purge_single_message(~s, datetime_to_mess_id(~p), get_now()),~n",
        [DateTime,
         pretty_print_jid(LocJID),
         MessDateTime]).

pretty_print_jid(#jid{luser = <<"alice">>}) -> "alice()";
pretty_print_jid(#jid{luser = <<"cat">>, lresource = <<"1">>})   -> "cat1()";
pretty_print_jid(#jid{luser = <<"cat">>, lresource = <<>>})      -> "cat()".

pretty_print_rsm(#rsm_in{index=Offset}) when is_integer(Offset) ->
    io_lib:format("#rsm_in{index=~p}", [Offset]);
pretty_print_rsm(#rsm_in{direction=Dir, id=undefined}) ->
    io_lib:format("#rsm_in{direction=~p}", [Dir]);
pretty_print_rsm(#rsm_in{direction=Dir, id=MessID}) ->
    {Microseconds, _} = mod_mam_utils:decode_compact_uuid(MessID),
    DateTime = microseconds_to_datetime(Microseconds),
    io_lib:format("#rsm_in{direction=~p, id=datetime_to_mess_id(~p)}", [Dir, DateTime]);
pretty_print_rsm(undefined) -> "undefined";
pretty_print_rsm(RSM) ->
    io_lib:format("~p", [RSM]).

pretty_print_microseconds(Microseconds) ->
    io_lib:format("~p", [Microseconds]).

-endif.
-endif.


%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------