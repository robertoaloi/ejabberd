-module(mod_mam_muc).
-behavior(gen_mod).
-export([start/2, stop/1]).
%% ejabberd handlers
-export([filter_room_packet/4,
         room_process_mam_iq/3,
         forget_room/2]).

%% Client API
-export([delete_archive/2,
         delete_archive_after_destruction/3,
         enable_logging/3,
         enable_querying/3,
         create_room_archive/2]).

-include_lib("ejabberd/include/ejabberd.hrl").
-include_lib("ejabberd/include/jlib.hrl").
-include_lib("exml/include/exml.hrl").

-define(MAYBE_BIN(X), (is_binary(X) orelse (X) =:= undefined)).

%% ----------------------------------------------------------------------
%% Datetime types
-type iso8601_datetime_binary() :: binary().
%% Seconds from 01.01.1970
-type unix_timestamp() :: non_neg_integer().

%% ----------------------------------------------------------------------
%% XMPP types
-type server_hostname() :: binary().
-type elem() :: #xmlel{}.
-type escaped_nick_name() :: binary(). 
-type escaped_room_id() :: binary(). 


%% ----------------------------------------------------------------------
%% Other types
-type filter() :: iolist().
-type escaped_message_id() :: binary().

%% ----------------------------------------------------------------------
%% Constants

mam_ns_string() -> "urn:xmpp:mam:tmp".

mam_ns_binary() -> <<"urn:xmpp:mam:tmp">>.

rsm_ns_binary() -> <<"http://jabber.org/protocol/rsm">>.

default_result_limit() -> 50.

max_result_limit() -> 50.

should_delete_archive_after_destruction_by_default(_LServer) -> true.

%% ----------------------------------------------------------------------
%% gen_mod callbacks

start(DefaultHost, Opts) ->
    Host = gen_mod:get_opt_host(DefaultHost, Opts, DefaultHost),
    start_supervisor(Host),
    ?DEBUG("mod_mam_muc starting", []),
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue), %% Type
    mod_disco:register_feature(Host, mam_ns_binary()),
    gen_iq_handler:add_iq_handler(mod_muc_iq, Host, mam_ns_binary(),
                                  ?MODULE, room_process_mam_iq, IQDisc),
    ejabberd_hooks:add(filter_room_packet, Host, ?MODULE,
                       filter_room_packet, 90),
    ejabberd_hooks:add(forget_room, Host, ?MODULE, forget_room, 90),
    ok.

stop(Host) ->
    stop_supervisor(Host),
    ?DEBUG("mod_mam stopping", []),
    ejabberd_hooks:add(filter_room_packet, Host, ?MODULE,
                       filter_room_packet, 90),
    gen_iq_handler:remove_iq_handler(mod_muc_iq, Host, mam_ns_string()),
    mod_disco:unregister_feature(Host, mam_ns_binary()),
    ok.

%% ----------------------------------------------------------------------
%% OTP helpers

sup_name() ->
    ejabberd_mod_mam_muc_sup.

start_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host, sup_name()),
    ChildSpec =
    {Proc,
     {mod_mam_muc_cache, start_link, []},
     permanent,
     5000,
     worker,
     [mod_mam_muc_cache]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host, sup_name()),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).


%% ----------------------------------------------------------------------
%% API

%% @doc Delete all messages from the room.
delete_archive(RoomName, LServer) ->
    RoomId = mod_mam_muc_cache:room_id(LServer, RoomName),
    SRoomId = integer_to_list(RoomId),
    %% TODO: use transaction
    {selected, _ColumnNames, _MessageRows} =
    ejabberd_odbc:sql_query(LServer,
    ["DELETE FROM mam_muc_message WHERE room_id = \"", SRoomId, "\""]),
    {selected, _ColumnNames, _MessageRows} =
    ejabberd_odbc:sql_query(LServer,
    ["DELETE FROM mam_muc_room WHERE id = \"", SRoomId, "\""]),
    true.

%% @doc All messages will be deleted after the room is destroyed.
%% If `DeleteIt' is true, than messages will be lost.
%% If `DeleteIt' is false, than messages will be stored.
%% If `DeleteIt' is undefined, then the default behaviour will be chosen.
delete_archive_after_destruction(LServer, RoomName, DeleteIt) ->
    set_bool(LServer, RoomName, "delete_archive_after_destruction", DeleteIt),
    ok.

%% @doc Enable logging for the room.
enable_logging(LServer, RoomName, Enabled) ->
    set_bool(LServer, RoomName, "enable_logging", Enabled),
    mod_mam_muc_cache:update_logging_enabled(LServer, RoomName, Enabled),
    ok.

%% @doc Enable access to the archive for the room.
enable_querying(LServer, RoomName, Enabled) ->
    set_bool(LServer, RoomName, "enable_querying", Enabled),
    mod_mam_muc_cache:update_querying_enabled(LServer, RoomName, Enabled),
    ok.

create_room_archive(LServer, RoomName) ->
    SRoomName = ejabberd_odbc:escape(RoomName),
    ejabberd_odbc:sql_query(
      LServer,
      ["INSERT INTO mam_muc_room(room_name) "
       "VALUES ('", SRoomName,"')"]),
    ok.


%% ----------------------------------------------------------------------
%% hooks and handlers

%% This hook is called from `mod_muc:forget_room(Host, Name)'.
forget_room(LServer, RoomName) ->
    ShouldDelete =
    case query_delete_archive_after_destruction(LServer, RoomName) of
        undefined ->
            should_delete_archive_after_destruction_by_default(LServer);
        Bool ->
            Bool
    end,
    case ShouldDelete of
        true -> delete_archive(RoomName, LServer);
        false -> false
    end.

%% @doc Handle public MUC-message.
filter_room_packet(Packet, FromNick, _FromJID,
                   To=#jid{lserver = LServer, luser = RoomName}) ->
    ?DEBUG("Incoming room packet.", []),
    case mod_mam_muc_cache:is_logging_enabled(LServer, RoomName) of
    false -> Packet;
    true ->
    RoomId = mod_mam_muc_cache:room_id(LServer, RoomName),
    SRoomId = integer_to_list(RoomId),
    SFromNick = ejabberd_odbc:escape(FromNick),
    SData = ejabberd_odbc:escape(term_to_binary(Packet)),
    AtomicF = fun() ->
    archive_message(LServer, SRoomId, SFromNick, SData),
    last_insert_id(LServer)
    end,
    {atomic, Id} = ejabberd_odbc:sql_transaction(LServer, AtomicF),
    ?DEBUG("Archived ~p", [Id]),
    BareTo = jlib:jid_to_binary(To),
    replace_archived_elem(BareTo, Id, Packet)
    end.

%% `process_mam_iq/3' is simular.
-spec room_process_mam_iq(From, To, IQ) -> IQ | ignore | error when
    From :: jid(),
    To :: jid(),
    IQ :: #iq{}.
room_process_mam_iq(From=#jid{lserver = LServer},
                    To=#jid{luser = RoomName},
                    IQ=#iq{type = get,
                           sub_el = QueryEl = #xmlel{name = <<"query">>}}) ->
    case mod_mam_muc_cache:is_querying_enabled(LServer, RoomName) of
    false -> error;
    true ->
    ?DEBUG("Handle IQ query.", []),
    QueryID = xml:get_tag_attr_s(<<"queryid">>, QueryEl),
    %% Filtering by date.
    %% Start :: integer() | undefined
    Start = maybe_unix_timestamp(xml:get_path_s(QueryEl, [{elem, <<"start">>}, cdata])),
    End   = maybe_unix_timestamp(xml:get_path_s(QueryEl, [{elem, <<"end">>}, cdata])),
    RSM   = jlib:rsm_decode(QueryEl),
    %% Filtering by contact.
    With  = xml:get_path_s(QueryEl, [{elem, <<"with">>}, cdata]),
    SWithNick =
    case With of
        <<>> -> undefined;
        _    -> 
            #jid{lresource = WithLResource} = jlib:binary_to_jid(With),
            ejabberd_odbc:escape(WithLResource)
    end,
    %% This element's name is "limit".
    %% But it must be "max" according XEP-0313.
    Limit = get_one_of_path_bin(QueryEl, [
                    [{elem, <<"set">>}, {elem, <<"max">>}, cdata],
                    [{elem, <<"set">>}, {elem, <<"limit">>}, cdata]
                   ]),
    PageSize = min(max_result_limit(),
                   maybe_integer(Limit, default_result_limit())),

    RoomId = mod_mam_muc_cache:room_id(LServer, RoomName),
    SRoomId = integer_to_list(RoomId),
    Filter = prepare_filter(SRoomId, Start, End, SWithNick),
    TotalCount = calc_count(LServer, Filter),
    Offset     = calc_offset(LServer, Filter, PageSize, TotalCount, RSM),
    ?DEBUG("RSM info: ~nTotal count: ~p~nOffset: ~p~n",
              [TotalCount, Offset]),
    %% If a query returns a number of stanzas greater than this limit and the
    %% client did not specify a limit using RSM then the server should return
    %% a policy-violation error to the client. 
    case TotalCount - Offset > max_result_limit() andalso Limit =:= <<>> of
        true ->
        ErrorEl = ?STANZA_ERRORT(<<"">>, <<"modify">>, <<"policy-violation">>,
                                 <<"en">>, <<"Too many results">>),          
        IQ#iq{type = error, sub_el = [ErrorEl]};

        false ->
        MessageRows = extract_messages(LServer, Filter, Offset, PageSize),
        {FirstId, LastId} =
            case MessageRows of
                []    -> {undefined, undefined};
                [_|_] -> {message_row_to_id(hd(MessageRows)),
                          message_row_to_id(lists:last(MessageRows))}
            end,
        [send_message(To, From, message_row_to_xml(M, To, QueryID))
         || M <- MessageRows],
        ResultSetEl = result_set(FirstId, LastId, Offset, TotalCount),
        ResultQueryEl = result_query(ResultSetEl),
        %% On receiving the query, the server pushes to the client a series of
        %% messages from the archive that match the client's given criteria,
        %% and finally returns the <iq/> result.
        IQ#iq{type = result, sub_el = [ResultQueryEl]}
    end
    end;
room_process_mam_iq(_, _, _) ->
    ?DEBUG("Bad IQ.", []),
    error.

%% ----------------------------------------------------------------------
%% Internal functions

send_message(From, To, Mess) ->
    ejabberd_sm:route(From, To, Mess).

%% @doc This element will be added into "iq/query".
-spec result_set(FirstId, LastId, FirstIndexI, CountI) -> elem() when
    FirstId :: binary() | undefined,
    LastId  :: binary() | undefined,
    FirstIndexI :: non_neg_integer() | undefined,
    CountI      :: non_neg_integer().
result_set(FirstId, LastId, FirstIndexI, CountI)
        when ?MAYBE_BIN(FirstId), ?MAYBE_BIN(LastId) ->
    %% <result xmlns='urn:xmpp:mam:tmp' queryid='f27' id='28482-98726-73623' />
    FirstEl = [#xmlel{name = <<"first">>,
                      attrs = [{<<"index">>, integer_to_binary(FirstIndexI)}],
                      children = [#xmlcdata{content = FirstId}]
                     }
               || FirstId =/= undefined],
    LastEl = [#xmlel{name = <<"last">>,
                     children = [#xmlcdata{content = LastId}]
                    }
               || LastId =/= undefined],
    CountEl = #xmlel{
            name = <<"count">>,
            children = [#xmlcdata{content = integer_to_binary(CountI)}]},
    #xmlel{
        name = <<"set">>,
        attrs = [{<<"xmlns">>, rsm_ns_binary()}],
        children = FirstEl ++ LastEl ++ [CountEl]}.

result_query(SetEl) ->
     #xmlel{
        name = <<"query">>,
        attrs = [{<<"xmlns">>, mam_ns_binary()}],
        children = [SetEl]}.

message_row_to_xml({BUID,BSeconds,BNick,BPacket}, RoomJID, QueryID) ->
    Packet = binary_to_term(BPacket),
    Seconds  = list_to_integer(binary_to_list(BSeconds)),
    DateTime = calendar:now_to_universal_time(seconds_to_now(Seconds)),
    FromJID = jlib:jid_replace_resource(RoomJID, BNick),
    wrap_message(Packet, QueryID, BUID, DateTime, FromJID).

message_row_to_id({BUID,_,_,_}) ->
    BUID.


%% @doc Form `<forwarded/>' element, according to the XEP.
-spec wrap_message(Packet::elem(), QueryID::binary(),
                   MessageUID::term(), DateTime::calendar:datetime(), FromJID::jid()) ->
        Wrapper::elem().
wrap_message(Packet, QueryID, MessageUID, DateTime, FromJID) ->
    #xmlel{
        name = <<"message">>,
        attrs = [],
        children = [result(QueryID, MessageUID,
                           [forwarded(Packet, DateTime, FromJID)])]}.

-spec forwarded(elem(), calendar:datetime(), jid()) -> elem().
forwarded(Packet, DateTime, FromJID) ->
    #xmlel{
        name = <<"forwarded">>,
        attrs = [{<<"xmlns">>, <<"urn:xmpp:forward:0">>}],
        children = [delay(DateTime, FromJID), Packet]}.

-spec delay(calendar:datetime(), jid()) -> elem().
delay(DateTime, FromJID) ->
    jlib:timestamp_to_xml(DateTime, utc, FromJID, <<>>).


%% @doc This element will be added in each forwarded message.
result(QueryID, MessageUID, Children) when is_list(Children) ->
    #xmlel{
        name = <<"result">>,
        attrs = [{<<"xmlns">>, mam_ns_binary()},
                 {<<"queryid">>, QueryID},
                 {<<"id">>, MessageUID}],
        children = Children}.

%% ----------------------------------------------------------------------
%% SQL Internal functions

archive_message(LServer, SRoomId, SNick, SData) ->
    Result =
    ejabberd_odbc:sql_query(
      LServer,
      ["INSERT INTO mam_muc_message(room_id, nick_name, "
                                    "message, added_at) "
       "VALUES ('", SRoomId, "', '", SNick, "', '", SData, "', ",
                integer_to_list(current_unix_timestamp()), ")"]),
    ?DEBUG("archive_message query returns ~p", [Result]),
    ok.

last_insert_id(LServer) ->
    {selected, [_], [{Id}]} =
    ejabberd_odbc:sql_query(LServer, "SELECT LAST_INSERT_ID()"),
    Id.

%% #rsm_in{
%%    max = non_neg_integer() | undefined,
%%    direction = before | aft | undefined,
%%    id = binary() | undefined,
%%    index = non_neg_integer() | undefined}
-spec calc_offset(LServer, Filter, PageSize, TotalCount, RSM) -> Offset
    when
    LServer  :: server_hostname(),
    Filter   :: filter(),
    PageSize :: non_neg_integer(),
    TotalCount :: non_neg_integer(),
    RSM      :: #rsm_in{},
    Offset   :: non_neg_integer().
calc_offset(_LS, _F, _PS, _TC, #rsm_in{direction = undefined, index = Index})
    when is_integer(Index) ->
    Index;
%% Requesting the Last Page in a Result Set
calc_offset(_LS, _F, PS, TC, #rsm_in{direction = before, id = <<>>}) ->
    max(0, TC - PS);
calc_offset(LServer, Filter, PageSize, _TC, #rsm_in{direction = before, id = ID})
    when is_binary(ID) ->
    SID = ejabberd_odbc:escape(ID),
    max(0, calc_before(LServer, Filter, SID) - PageSize);
calc_offset(LServer, Filter, _PS, _TC, #rsm_in{direction = aft, id = ID})
    when is_binary(ID), byte_size(ID) > 0 ->
    SID = ejabberd_odbc:escape(ID),
    calc_index(LServer, Filter, SID);
calc_offset(_LS, _F, _PS, _TC, _RSM) ->
    0.

%% Zero-based index of the row with UID in the result test.
%% If the element does not exists, the ID of the next element will
%% be returned instead.
%% "SELECT COUNT(*) as "index" FROM mam_muc_message WHERE id <= '",  UID
-spec calc_index(LServer, Filter, SUID) -> Count
    when
    LServer  :: server_hostname(),
    Filter   :: filter(),
    SUID     :: escaped_message_id(),
    Count    :: non_neg_integer().
calc_index(LServer, Filter, SUID) ->
    {selected, _ColumnNames, [{BIndex}]} =
    ejabberd_odbc:sql_query(
      LServer,
      ["SELECT COUNT(*) FROM mam_muc_message ", Filter, " AND id <= '", SUID, "'"]),
    list_to_integer(binary_to_list(BIndex)).

%% @doc Count of elements in RSet before the passed element.
%% The element with the passed UID can be already deleted.
%% "SELECT COUNT(*) as "count" FROM mam_muc_message WHERE id < '",  UID
-spec calc_before(LServer, Filter, SUID) -> Count
    when
    LServer  :: server_hostname(),
    Filter   :: filter(),
    SUID     :: escaped_message_id(),
    Count    :: non_neg_integer().
calc_before(LServer, Filter, SUID) ->
    {selected, _ColumnNames, [{BIndex}]} =
    ejabberd_odbc:sql_query(
      LServer,
      ["SELECT COUNT(*) FROM mam_muc_message ", Filter, " AND id < '", SUID, "'"]),
    list_to_integer(binary_to_list(BIndex)).


%% @doc Get the total result set size.
%% "SELECT COUNT(*) as "count" FROM mam_muc_message WHERE "
-spec calc_count(LServer, Filter) -> Count
    when
    LServer  :: server_hostname(),
    Filter   :: filter(),
    Count    :: non_neg_integer().
calc_count(LServer, Filter) ->
    {selected, _ColumnNames, [{BCount}]} =
    ejabberd_odbc:sql_query(
      LServer,
      ["SELECT COUNT(*) FROM mam_muc_message ", Filter]),
    list_to_integer(binary_to_list(BCount)).

-spec prepare_filter(SRoomId, IStart, IEnd, SWithNick) -> filter()
    when
    SRoomId   :: escaped_room_id(),
    IStart    :: unix_timestamp() | undefined,
    IEnd      :: unix_timestamp() | undefined,
    SWithNick :: escaped_nick_name().
prepare_filter(SRoomId, IStart, IEnd, SWithNick) ->
   ["WHERE room_id='", SRoomId, "'",
     case IStart of
        undefined -> "";
        _         -> [" AND added_at >= ", integer_to_list(IStart)]
     end,
     case IEnd of
        undefined -> "";
        _         -> [" AND added_at <= ", integer_to_list(IEnd)]
     end,
     case SWithNick of
        undefined -> "";
        _         -> [" AND nick_name = '", SWithNick, "'"]
     end].

%% Columns are `["id","added_at","nick_name","message"]'.
-spec extract_messages(LServer, Filter, IOffset, IMax) ->
    [Record] when
    LServer :: server_hostname(),
    Filter  :: filter(),
    IOffset :: non_neg_integer(),
    IMax    :: pos_integer(),
    Record :: tuple().
extract_messages(_LServer, _Filter, _IOffset, 0) ->
    [];
extract_messages(LServer, Filter, IOffset, IMax) ->
    {selected, _ColumnNames, MessageRows} =
    ejabberd_odbc:sql_query(
      LServer,
      ["SELECT id, added_at, nick_name, message "
       "FROM mam_muc_message ",
        Filter,
       " ORDER BY added_at, id"
       " LIMIT ",
         case IOffset of
             0 -> "";
             _ -> [integer_to_list(IOffset), ", "]
         end,
         integer_to_list(IMax)]),
    ?DEBUG("extract_messages query returns ~p", [MessageRows]),
    MessageRows.

sql_bool(true)      -> "\"1\"";
sql_bool(false)     -> "\"0\"";
sql_bool(undefined) -> "null".

set_bool(LServer, RoomName, FieldName, FieldValue) ->
    RoomId = mod_mam_muc_cache:room_id(LServer, RoomName),
    SRoomId = integer_to_list(RoomId),
    ejabberd_odbc:sql_query(
      LServer,
      ["UPDATE mam_muc_room "
       "SET ", FieldName, " = ", sql_bool(FieldValue), " "
       "WHERE id = \"", SRoomId, "\""]).

query_delete_archive_after_destruction(LServer, RoomName) ->
    select_bool(LServer, RoomName, "delete_archive_after_destruction").

select_bool(LServer, RoomName, Field) ->
    SRoomName = ejabberd_odbc:escape(RoomName),
    Result =
    ejabberd_odbc:sql_query(
      LServer,
      ["SELECT " ++ Field ++ " "
       "FROM mam_muc_room "
       "WHERE room_name='", SRoomName, "' "
       "LIMIT 1"]),

    case Result of
        {selected, [Field], [{Res}]} ->
            case Res of
                null    -> undefined;
                <<"1">> -> true;
                <<"0">> -> false
            end;
        {selected, [Field], []} ->
            %% The room is not found
            create_room_archive(LServer, RoomName),
            undefined
    end.


%% ----------------------------------------------------------------------
%% Helpers

%% "maybe" means, that the function may return 'undefined'.
-spec maybe_unix_timestamp(iso8601_datetime_binary()) -> unix_timestamp();
                          (<<>>) -> undefined.
maybe_unix_timestamp(<<>>) -> undefined;
maybe_unix_timestamp(ISODateTime) -> 
    case iso8601_datetime_binary_to_timestamp(ISODateTime) of
        undefined -> undefined;
        Stamp -> now_to_seconds(Stamp)
    end.

-spec current_unix_timestamp() -> unix_timestamp().
current_unix_timestamp() ->
    now_to_seconds(os:timestamp()).

-spec now_to_seconds(erlang:timestamp()) -> unix_timestamp().
now_to_seconds({Mega, Secs, _}) ->
    1000000 * Mega + Secs.

-spec seconds_to_now(unix_timestamp()) -> erlang:timestamp().
seconds_to_now(Seconds) when is_integer(Seconds) ->
    {Seconds div 1000000, Seconds rem 1000000, 0}.

%% @doc Returns time in `now()' format.
-spec iso8601_datetime_binary_to_timestamp(iso8601_datetime_binary()) ->
    erlang:timestamp().
iso8601_datetime_binary_to_timestamp(DateTime) when is_binary(DateTime) ->
    jlib:datetime_string_to_timestamp(binary_to_list(DateTime)).


maybe_integer(<<>>, Def) -> Def;
maybe_integer(Bin, _Def) when is_binary(Bin) ->
    list_to_integer(binary_to_list(Bin)).


get_one_of_path_bin(Elem, List) ->
    get_one_of_path(Elem, List, <<>>).

get_one_of_path(Elem, [H|T], Def) ->
    case xml:get_path_s(Elem, H) of
        Def -> get_one_of_path(Elem, T, Def);
        Val  -> Val
    end;
get_one_of_path(_Elem, [], Def) ->
    Def.


replace_archived_elem(By, Id, Packet) ->
    append_archived_elem(By, Id,
    delete_archived_elem(By, Packet)).

append_archived_elem(By, Id, Packet) ->
    Archived = #xmlel{
        name = <<"archived">>,
        attrs=[{<<"by">>, By}, {<<"id">>, Id}]},
    xml:append_subtags(Packet, [Archived]).

delete_archived_elem(By, Packet=#xmlel{children=Cs}) ->
    Packet#xmlel{children=[C || C <- Cs, not is_archived_elem_for(C, By)]}.

%% @doc Return true, if the first element points on `By'.
is_archived_elem_for(#xmlel{name = <<"archived">>, attrs=As}, By) ->
    lists:member({<<"by">>, By}, As);
is_archived_elem_for(_, _) ->
    false.