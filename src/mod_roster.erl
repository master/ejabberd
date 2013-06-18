%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

%%% @doc Roster management (Mnesia storage).
%%%
%%% Includes support for XEP-0237: Roster Versioning.
%%% The roster versioning follows an all-or-nothing strategy:
%%%  - If the version supplied by the client is the latest, return an empty response.
%%%  - If not, return the entire new roster (with updated version string).
%%% Roster version is a hash digest of the entire roster.
%%% No additional data is stored in DB.
 
%%%----------------------------------------------------------------------
%%%
%%% Add following line in your ejabberd.cfg file to configure mod_roster_redis
%%%
%%% {mod_roster_redis,  [{redis_host, "localhost"}, {redis_port, 6379}, {redis_password, none|password}]},
%%%
%%%----------------------------------------------------------------------
-module(mod_roster).
-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1,
	 process_iq/3,
	 process_local_iq/3,
	 get_user_roster/2,
	 get_subscription_lists/3,
	 get_in_pending_subscriptions/3,
	 in_subscription/6,
	 out_subscription/4,
	 set_items/3,
	 remove_user/2,
	 get_jid_info/4,
	 item_to_xml/1,
	 webadmin_page/3,
	 webadmin_user/4,
	 get_versioning_feature/2,
	 roster_versioning_enabled/1,
	 roster_version/2]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("mod_roster.hrl").
-include("web/ejabberd_http.hrl").
-include("web/ejabberd_web_admin.hrl").


start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    case gen_mod:db_type(Opts) of
       mnesia ->
            mnesia:create_table(roster,
                                [{disc_copies, [node()]},
                                 {attributes, record_info(fields, roster)}]),
            mnesia:create_table(roster_version,
                                [{disc_copies, [node()]},
                                 {attributes,
                                  record_info(fields, roster_version)}]),
            update_table(),
            mnesia:add_table_index(roster, us),
            mnesia:add_table_index(roster_version, us);
       _ ->
            ok
    end,
    ejabberd_hooks:add(roster_get, Host,
		       ?MODULE, get_user_roster, 50),
    ejabberd_hooks:add(roster_in_subscription, Host,
		       ?MODULE, in_subscription, 50),
    ejabberd_hooks:add(roster_out_subscription, Host,
		       ?MODULE, out_subscription, 50),
    ejabberd_hooks:add(roster_get_subscription_lists, Host,
		       ?MODULE, get_subscription_lists, 50),
    ejabberd_hooks:add(roster_get_jid_info, Host,
		       ?MODULE, get_jid_info, 50),
    ejabberd_hooks:add(remove_user, Host,
		       ?MODULE, remove_user, 50),
    ejabberd_hooks:add(anonymous_purge_hook, Host,
		       ?MODULE, remove_user, 50),
    ejabberd_hooks:add(resend_subscription_requests_hook, Host,
		       ?MODULE, get_in_pending_subscriptions, 50),
    ejabberd_hooks:add(roster_get_versioning_feature, Host,
		       ?MODULE, get_versioning_feature, 50),
    ejabberd_hooks:add(webadmin_page_host, Host,
		       ?MODULE, webadmin_page, 50),
    ejabberd_hooks:add(webadmin_user, Host,
		       ?MODULE, webadmin_user, 50),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_ROSTER,
				  ?MODULE, process_iq, IQDisc).

stop(Host) ->
    ejabberd_hooks:delete(roster_get, Host,
			  ?MODULE, get_user_roster, 50),
    ejabberd_hooks:delete(roster_in_subscription, Host,
			  ?MODULE, in_subscription, 50),
    ejabberd_hooks:delete(roster_out_subscription, Host,
			  ?MODULE, out_subscription, 50),
    ejabberd_hooks:delete(roster_get_subscription_lists, Host,
			  ?MODULE, get_subscription_lists, 50),
    ejabberd_hooks:delete(roster_get_jid_info, Host,
			  ?MODULE, get_jid_info, 50),
    ejabberd_hooks:delete(remove_user, Host,
			  ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(anonymous_purge_hook, Host,
			  ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(resend_subscription_requests_hook, Host,
			  ?MODULE, get_in_pending_subscriptions, 50),
    ejabberd_hooks:delete(roster_get_versioning_feature, Host,
		          ?MODULE, get_versioning_feature, 50),
    ejabberd_hooks:delete(webadmin_page_host, Host,
			  ?MODULE, webadmin_page, 50),
    ejabberd_hooks:delete(webadmin_user, Host,
			  ?MODULE, webadmin_user, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_ROSTER).


process_iq(From, To, IQ) ->
    #iq{sub_el = SubEl} = IQ,
    #jid{lserver = LServer} = From,
    case lists:member(LServer, ?MYHOSTS) of
	true ->
	    process_local_iq(From, To, IQ);
	_ ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_ITEM_NOT_FOUND]}
    end.

process_local_iq(From, To, #iq{type = Type} = IQ) ->
    case Type of
	set ->
	    process_iq_set(From, To, IQ);
	get ->
	    process_iq_get(From, To, IQ)
    end.

roster_hash(Items) ->
	sha:sha(term_to_binary(
		lists:sort(
			[R#roster{groups = lists:sort(Grs)} || 
				R = #roster{groups = Grs} <- Items]))).
		
roster_versioning_enabled(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, versioning, false).

roster_version_on_db(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, store_current_id, false).

%% Returns a list that may contain an xmlelement with the XEP-237 feature if it's enabled.
get_versioning_feature(Acc, Host) ->
    case roster_versioning_enabled(Host) of
	true ->
	    Feature = {xmlelement,
		       "ver",
		       [{"xmlns", ?NS_ROSTER_VER}],
		       []},
	    [Feature | Acc];
	false -> []
    end.

roster_version(LServer, LUser) ->
    US = {LUser, LServer},
    case roster_version_on_db(LServer) of
        true ->
            case read_roster_version(LUser, LServer) of
                error ->
                    not_found;
                V ->
                    V
            end;
        false ->
            roster_hash(ejabberd_hooks:run_fold(roster_get, LServer, [], [US]))
    end.

read_roster_version(LUser, LServer) ->
    read_roster_version(LUser, LServer, gen_mod:db_type(LServer, ?MODULE)).

read_roster_version(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    case mnesia:dirty_read(roster_version, US) of
        [#roster_version{version = V}] -> V;
        [] -> error
    end;
read_roster_version(LUser, LServer, redis) ->
    Redis_host = redis_host(LServer),
    Redis_port = redis_port(LServer),
    Redis_database = redis_database(LServer),
    Redis_password = redis_password(LServer),
    {ok, C} = case Redis_password of
                none -> eredis:start_link(Redis_host, Redis_port, Redis_database, no_dbselection);
                _ -> eredis:start_link(Redis_host, Redis_port, Redis_database, Redis_password, no_dbselection)
              end,
    case catch eredis:q(C, ["GET", "rosterversion::" ++ LUser ++ "," ++ LServer]) of
        {ok, BVersion} when is_binary(BVersion) -> binary_to_list(BVersion);
        _ -> error 
    end;    
read_roster_version(LServer, LUser, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    case odbc_queries:get_roster_version(LServer, Username) of
        {selected, ["version"], [{Version}]} ->
            Version;
        {selected, ["version"], []} ->
            error
    end.

write_roster_version(LUser, LServer) ->
    write_roster_version(LUser, LServer, false).

write_roster_version_t(LUser, LServer) ->
    write_roster_version(LUser, LServer, true).

write_roster_version(LUser, LServer, InTransaction) ->
    Ver = sha:sha(term_to_binary(now())),
    write_roster_version(LUser, LServer, InTransaction, Ver,
                         gen_mod:db_type(LServer, ?MODULE)),
    Ver.

write_roster_version(LUser, LServer, InTransaction, Ver, mnesia) ->
    US = {LUser, LServer},
    if InTransaction ->
            mnesia:write(#roster_version{us = US, version = Ver});
       true ->
            mnesia:dirty_write(#roster_version{us = US, version = Ver})
    end;
write_roster_version(LUser, LServer, _InTransaction, Ver, redis) ->
    Redis_host = redis_host(LServer),
    Redis_port = redis_port(LServer),
    Redis_database = redis_database(LServer),
    Redis_password = redis_password(LServer),
    {ok, C} = case Redis_password of
                none -> eredis:start_link(Redis_host, Redis_port, Redis_database, no_dbselection);
                _ -> eredis:start_link(Redis_host, Redis_port, Redis_database, Redis_password, no_dbselection)
              end,
    eredis:q(C, ["SET", "rosterversion:" ++ LUser ++ "," ++ LServer, Ver]),
    ok;
write_roster_version(LUser, LServer, InTransaction, Ver, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    EVer = ejabberd_odbc:escape(Ver),
    if InTransaction ->
            odbc_queries:set_roster_version(Username, EVer);
       true ->
            odbc_queries:sql_transaction(
              LServer,
              fun() ->
                      odbc_queries:set_roster_version(Username, EVer)
              end)
    end.

%% Load roster from DB only if neccesary. 
%% It is neccesary if
%%     - roster versioning is disabled in server OR
%%     - roster versioning is not used by the client OR
%%     - roster versioning is used by server and client, BUT the server isn't storing versions on db OR
%%     - the roster version from client don't match current version.
process_iq_get(From, To, #iq{sub_el = SubEl} = IQ) ->
    LUser = From#jid.luser,
    LServer = From#jid.lserver,
    US = {LUser, LServer},
    try
        {ItemsToSend, VersionToSend} = 
            case {xml:get_tag_attr("ver", SubEl), 
                  roster_versioning_enabled(LServer),
                  roster_version_on_db(LServer)} of
		{{value, RequestedVersion}, true, true} ->
                    %% Retrieve version from DB. Only load entire roster
                    %% when neccesary.
                    case read_roster_version(LUser, LServer) of
                        error ->
                            RosterVersion = write_roster_version(LUser, LServer),
                            {lists:map(
                               fun item_to_xml/1,
                               ejabberd_hooks:run_fold(
                                 roster_get, To#jid.lserver, [], [US])),
                             RosterVersion};
                        RequestedVersion ->
                            {false, false};
                        NewVersion ->
                            {lists:map(
                               fun item_to_xml/1, 
                               ejabberd_hooks:run_fold(
                                 roster_get, To#jid.lserver, [], [US])),
                             NewVersion}
                    end;
		{{value, RequestedVersion}, true, false} ->
                    RosterItems = ejabberd_hooks:run_fold(
                                    roster_get, To#jid.lserver, [] , [US]),
                    case roster_hash(RosterItems) of
                        RequestedVersion ->
                            {false, false};
                        New ->
                            {lists:map(fun item_to_xml/1, RosterItems), New}
                    end;
		_ ->
                    {lists:map(
                       fun item_to_xml/1, 
                       ejabberd_hooks:run_fold(
                         roster_get, To#jid.lserver, [], [US])),
                     false}
            end,
        IQ#iq{type = result,
              sub_el = case {ItemsToSend, VersionToSend} of
                           {false, false} ->
                               [];
                           {Items, false} ->
                               [{xmlelement, "query",
                                 [{"xmlns", ?NS_ROSTER}], Items}];
                           {Items, Version} ->
                               [{xmlelement, "query",
                                 [{"xmlns", ?NS_ROSTER}, {"ver", Version}],
                                 Items}]
                       end}
    catch
    	_:_ ->  
            IQ#iq{type =error, sub_el = [SubEl, ?ERR_INTERNAL_SERVER_ERROR]}
    end.

get_user_roster(Acc, {LUser, LServer}) ->
    Items = get_roster(LUser, LServer),
    lists:filter(fun(#roster{subscription = none, ask = in}) ->
                         false;
                    (_) ->
                         true
                 end, Items) ++ Acc.

get_roster(LUser, LServer) ->
    get_roster(LUser, LServer, gen_mod:db_type(LServer, ?MODULE)).

get_roster(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    case catch mnesia:dirty_index_read(roster, US, #roster.us) of
	Items when is_list(Items) ->
            Items;
        _ ->
            []
    end;
get_roster(LUser, LServer, redis) ->
    Redis_host = redis_host(LServer),
    Redis_port = redis_port(LServer),
    Redis_database = redis_database(LServer),
    Redis_password = redis_password(LServer),
    {ok, C} = case Redis_password of
                none -> eredis:start_link(Redis_host, Redis_port, Redis_database, no_dbselection);
                _ -> eredis:start_link(Redis_host, Redis_port, Redis_database, Redis_password, no_dbselection)
              end,
    case catch eredis:q(C, ["HGETALL", "rosterusers::" ++ LUser ]) of
        {ok, BListEntries} when is_list(BListEntries) ->
            Entries = redis_make_list_entries(BListEntries),
            redis_make_roster_user( LUser, LServer, Entries);
        _ ->
            []
    end;
get_roster(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    case catch odbc_queries:get_roster(LServer, Username) of
	{selected, ["username", "jid", "nick", "subscription", "ask",
		    "askmessage", "server", "subscribe", "type"],
	 Items} when is_list(Items) ->
	    JIDGroups = case catch odbc_queries:get_roster_jid_groups(LServer, Username) of
			    {selected, ["jid","grp"], JGrps}
			    when is_list(JGrps) ->
				JGrps;
			    _ ->
				[]
			end,
            GroupsDict =
                lists:foldl(
                  fun({J, G}, Acc) ->
                          dict:append(J, G, Acc)
                  end, dict:new(), JIDGroups),
	    RItems = lists:flatmap(
		       fun(I) ->
			       case raw_to_record(LServer, I) of
				   %% Bad JID in database:
				   error ->
				       [];
				   R ->
				       SJID = jlib:jid_to_string(R#roster.jid),
				       Groups =
                                           case dict:find(SJID, GroupsDict) of
                                               {ok, Gs} -> Gs;
                                               error -> []
                                           end,
				       [R#roster{groups = Groups}]
			       end
		       end, Items),
	    RItems;
	_ ->
	    []
    end.


item_to_xml(Item) ->
    Attrs1 = [{"jid", jlib:jid_to_string(Item#roster.jid)}],
    Attrs2 = case Item#roster.name of
		 "" ->
		     Attrs1;
		 Name ->
		     [{"name", Name} | Attrs1]
	     end,
    Attrs3 = case Item#roster.subscription of
		 none ->
		     [{"subscription", "none"} | Attrs2];
		 from ->
		     [{"subscription", "from"} | Attrs2];
		 to ->
		     [{"subscription", "to"} | Attrs2];
		 both ->
		     [{"subscription", "both"} | Attrs2];
		 remove ->
		     [{"subscription", "remove"} | Attrs2]
	     end,
    Attrs4 = case ask_to_pending(Item#roster.ask) of
		 out ->
		     [{"ask", "subscribe"} | Attrs3];
		 both ->
		     [{"ask", "subscribe"} | Attrs3];
		 _ ->
		     Attrs3
	     end,
    SubEls1 = lists:map(fun(G) ->
				{xmlelement, "group", [], [{xmlcdata, G}]}
			end, Item#roster.groups),
    SubEls = SubEls1 ++ Item#roster.xs,
    {xmlelement, "item", Attrs4, SubEls}.

get_roster_by_jid_t(LUser, LServer, LJID) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    get_roster_by_jid_t(LUser, LServer, LJID, DBType).

get_roster_by_jid_t(LUser, LServer, LJID, mnesia) ->
    case mnesia:read({roster, {LUser, LServer, LJID}}) of
        [] ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer},
                    jid = LJID};
        [I] ->
            I#roster{jid = LJID,
                     name = "",
                     groups = [],
                     xs = []}
    end;
get_roster_by_jid_t(LUser, LServer, LJID, redis) ->
    Entries = get_roster(LUser, LServer, redis),
    case [Entry || Entry <- Entries, Entry#roster.jid == LJID] of 
        [] -> 
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer},
                    jid = LJID};
        [R] -> R
    end;
get_roster_by_jid_t(LUser, LServer, LJID, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    {selected,
     ["username", "jid", "nick", "subscription",
      "ask", "askmessage", "server", "subscribe", "type"],
     Res} = odbc_queries:get_roster_by_jid(LServer, Username, SJID),
    case Res of
        [] ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer},
                    jid = LJID};
        [I] ->
            R = raw_to_record(LServer, I),
            case R of
                %% Bad JID in database:
                error ->
                    #roster{usj = {LUser, LServer, LJID},
                            us = {LUser, LServer},
                            jid = LJID};
                _ ->
                    R#roster{
                      usj = {LUser, LServer, LJID},
                      us = {LUser, LServer},
                      jid = LJID,
                      name = ""}
            end
    end.

process_iq_set(From, To, #iq{sub_el = SubEl} = IQ) ->
    {xmlelement, _Name, _Attrs, Els} = SubEl,
    lists:foreach(fun(El) -> process_item_set(From, To, El) end, Els),
    IQ#iq{type = result, sub_el = []}.

process_item_set(From, To, {xmlelement, _Name, Attrs, Els}) ->
    JID1 = jlib:string_to_jid(xml:get_attr_s("jid", Attrs)),
    #jid{user = User, luser = LUser, lserver = LServer} = From,
    case JID1 of
	error ->
	    ok;
	_ ->
	    LJID = jlib:jid_tolower(JID1),
	    F = fun() ->
            Item = get_roster_by_jid_t(LUser, LServer, LJID),
			Item1 = process_item_attrs(Item, Attrs),
			Item2 = process_item_els(Item1, Els),
			case Item2#roster.subscription of
			    remove ->
                                del_roster_t(LUser, LServer, LJID);
			    _ ->
                                update_roster_t(LUser, LServer, LJID, Item2)
			end,
			%% If the item exist in shared roster, take the
			%% subscription information from there:
			Item3 = ejabberd_hooks:run_fold(roster_process_item,
							LServer, Item2, [LServer]),
			case roster_version_on_db(LServer) of
                            true -> write_roster_version_t(LUser, LServer);
                            false -> ok
			end,
			{Item, Item3}
		end,
	    case transaction(LServer, F) of
		{atomic, {OldItem, Item}} ->
		    push_item(User, LServer, To, Item),
		    case Item#roster.subscription of
			remove ->
			    send_unsubscribing_presence(From, OldItem),
			    ok;
			_ ->
			    ok
		    end;
		E ->
		    ?DEBUG("ROSTER: roster item set error: ~p~n", [E]),
		    ok
	    end
    end;
process_item_set(_From, _To, _) ->
    ok.

process_item_attrs(Item, [{Attr, Val} | Attrs]) ->
    case Attr of
	"jid" ->
	    case jlib:string_to_jid(Val) of
		error ->
		    process_item_attrs(Item, Attrs);
		JID1 ->
		    JID = {JID1#jid.luser, JID1#jid.lserver, JID1#jid.lresource},
		    process_item_attrs(Item#roster{jid = JID}, Attrs)
	    end;
	"name" ->
	    process_item_attrs(Item#roster{name = Val}, Attrs);
	"subscription" ->
	    case Val of
		"remove" ->
		    process_item_attrs(Item#roster{subscription = remove},
				       Attrs);
		_ ->
		    process_item_attrs(Item, Attrs)
	    end;
	"ask" ->
	    process_item_attrs(Item, Attrs);
	_ ->
	    process_item_attrs(Item, Attrs)
    end;
process_item_attrs(Item, []) ->
    Item.


process_item_els(Item, [{xmlelement, Name, Attrs, SEls} | Els]) ->
    case Name of
	"group" ->
	    Groups = [xml:get_cdata(SEls) | Item#roster.groups],
	    process_item_els(Item#roster{groups = Groups}, Els);
	_ ->
	    case xml:get_attr_s("xmlns", Attrs) of
		"" ->
		    process_item_els(Item, Els);
		_ ->
		    XEls = [{xmlelement, Name, Attrs, SEls} | Item#roster.xs],
		    process_item_els(Item#roster{xs = XEls}, Els)
	    end
    end;
process_item_els(Item, [{xmlcdata, _} | Els]) ->
    process_item_els(Item, Els);
process_item_els(Item, []) ->
    Item.


push_item(User, Server, From, Item) ->
    ejabberd_sm:route(jlib:make_jid("", "", ""),
		      jlib:make_jid(User, Server, ""),
		      {xmlelement, "broadcast", [],
		       [{item,
			 Item#roster.jid,
			 Item#roster.subscription}]}),
    case roster_versioning_enabled(Server) of
	true ->
		push_item_version(Server, User, From, Item, roster_version(Server, User));
	false ->
	    lists:foreach(fun(Resource) ->
			  push_item(User, Server, Resource, From, Item)
		  end, ejabberd_sm:get_user_resources(User, Server))
    end.

% TODO: don't push to those who didn't load roster
push_item(User, Server, Resource, From, Item) ->
    push_item(User, Server, Resource, From, Item, not_found).

push_item(User, Server, Resource, From, Item, RosterVersion) ->
    ExtraAttrs = case RosterVersion of
	not_found -> [];
	_ -> [{"ver", RosterVersion}]
    end,
    ResIQ = #iq{type = set, xmlns = ?NS_ROSTER,
		id = "push" ++ randoms:get_string(),
		sub_el = [{xmlelement, "query",
			   [{"xmlns", ?NS_ROSTER}|ExtraAttrs],
			   [item_to_xml(Item)]}]},
    ejabberd_router:route(
      From,
      jlib:make_jid(User, Server, Resource),
      jlib:iq_to_xml(ResIQ)).

%% @doc Roster push, calculate and include the version attribute.
%% TODO: don't push to those who didn't load roster
push_item_version(Server, User, From, Item, RosterVersion)  ->
    lists:foreach(fun(Resource) ->
			  push_item(User, Server, Resource, From, Item, RosterVersion)
		end, ejabberd_sm:get_user_resources(User, Server)).

get_subscription_lists(Acc, User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    DBType = gen_mod:db_type(LServer, ?MODULE),
    Items = get_subscription_lists(Acc, LUser, LServer, DBType),
    fill_subscription_lists(LServer, Items, [], []).

get_subscription_lists(_, LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    case mnesia:dirty_index_read(roster, US, #roster.us) of
	Items when is_list(Items) ->
            Items;
	_ ->
            []
    end;
get_subscription_lists(_, LUser, LServer, redis) ->
    get_roster(LUser, LServer, redis);
get_subscription_lists(_, LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    case catch odbc_queries:get_roster(LServer, Username) of
	{selected, ["username", "jid", "nick", "subscription", "ask",
		    "askmessage", "server", "subscribe", "type"],
	 Items} when is_list(Items) ->
            Items;
        _ ->
            []
    end.
fill_subscription_lists(LServer, [#roster{} = I | Is], F, T) ->
    J = element(3, I#roster.usj),
    case I#roster.subscription of
	both ->
	    fill_subscription_lists(LServer, Is, [J | F], [J | T]);
	from ->
	    fill_subscription_lists(LServer, Is, [J | F], T);
	to ->
	    fill_subscription_lists(LServer, Is, F, [J | T]);
	_ ->
	    fill_subscription_lists(LServer, Is, F, T)
    end;
fill_subscription_lists(LServer, [RawI | Is], F, T) ->
    I = raw_to_record(LServer, RawI),
    case I of
	%% Bad JID in database:
	error ->
	    fill_subscription_lists(LServer, Is, F, T);
	_ ->
            fill_subscription_lists(LServer, [I | Is], F, T)
    end;
fill_subscription_lists(_LServer, [], F, T) ->
    {F, T}.

ask_to_pending(subscribe) -> out;
ask_to_pending(unsubscribe) -> none;
ask_to_pending(Ask) -> Ask.

roster_subscribe_t(LUser, LServer, LJID, Item) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    roster_subscribe_t(LUser, LServer, LJID, Item, DBType).

roster_subscribe_t(_LUser, _LServer, _LJID, Item, mnesia) ->
    mnesia:write(Item);
roster_subscribe_t(LUser, LServer, LJID, Item, redis) ->
    Redis_host = redis_host(LServer),
    Redis_port = redis_port(LServer),
    {RUser, RServer, _} = LJID,
    Redis_database = redis_database(LServer),
    Redis_password = redis_password(LServer),
    Name = Item#roster.name,
    Subscription = redis_subscription_to_string(Item#roster.subscription),
    Ask = redis_ask_to_string(Item#roster.ask),
    AskMessage = redis_askmessage_to_string(Item#roster.askmessage),
    Groups = 
        case Item#roster.groups of
            [Grp] when is_list(Grp) -> Grp;
            Grps when is_list(Grps) -> string:join(Grps, ",");
            [] -> ""
        end,
    NewRosterEntry = Name ++ "::" ++ Subscription ++ "::" ++ Ask ++ "::" ++ AskMessage ++ "::" ++ Groups,
    {ok, C} = case Redis_password of
                none -> eredis:start_link(Redis_host, Redis_port, Redis_database, no_dbselection);
                _ -> eredis:start_link(Redis_host, Redis_port, Redis_database, Redis_password, no_dbselection)
              end,
    eredis:q(C, ["HSET", "rosterusers::" ++ LUser, RUser ++ "@" ++ RServer, NewRosterEntry]),
    ok;
roster_subscribe_t(LUser, LServer, LJID, Item, odbc) ->
    ItemVals = record_to_string(Item),
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    odbc_queries:roster_subscribe(LServer, Username, SJID, ItemVals).

transaction(LServer, F) ->
    case gen_mod:db_type(LServer, ?MODULE) of
        mnesia ->
            mnesia:transaction(F);
        redis ->
            {atomic, F()};
        odbc ->
            ejabberd_odbc:sql_transaction(LServer, F)
    end.

in_subscription(_, User, Server, JID, Type, Reason) ->
    process_subscription(in, User, Server, JID, Type, Reason).

out_subscription(User, Server, JID, Type) ->
    process_subscription(out, User, Server, JID, Type, []).

get_roster_by_jid_with_groups_t(LUser, LServer, LJID) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    get_roster_by_jid_with_groups_t(LUser, LServer, LJID, DBType).

get_roster_by_jid_with_groups_t(LUser, LServer, LJID, mnesia) ->
    case mnesia:read({roster, {LUser, LServer, LJID}}) of
        [] ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer},
                    jid = LJID};
        [I] ->
            I
    end;
get_roster_by_jid_with_groups_t(LUser, LServer, LJID, redis) ->
    Entries = get_roster(LUser, LServer, redis),
    case [Entry || Entry <- Entries, Entry#roster.jid == LJID] of
        [] ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer},
                    jid = LJID};
        [R] -> R
    end;
get_roster_by_jid_with_groups_t(LUser, LServer, LJID, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    case odbc_queries:get_roster_by_jid(LServer, Username, SJID) of
        {selected,
         ["username", "jid", "nick", "subscription", "ask",
          "askmessage", "server", "subscribe", "type"],
         [I]} ->
            %% raw_to_record can return error, but
            %% jlib_to_string would fail before this point
            R = raw_to_record(LServer, I),
            Groups =
                case odbc_queries:get_roster_groups(LServer, Username, SJID) of
                    {selected, ["grp"], JGrps} when is_list(JGrps) ->
                        [JGrp || {JGrp} <- JGrps];
                    _ ->
                        []
                end,
            R#roster{groups = Groups};
        {selected,
         ["username", "jid", "nick", "subscription", "ask",
          "askmessage", "server", "subscribe", "type"],
         []} ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer},
                    jid = LJID}
    end.

process_subscription(Direction, User, Server, JID1, Type, Reason) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    LJID = jlib:jid_tolower(JID1),
    F = fun() ->
		Item = get_roster_by_jid_with_groups_t(
                         LUser, LServer, LJID),
		NewState = case Direction of
			       out ->
				   out_state_change(Item#roster.subscription,
						    Item#roster.ask,
						    Type);
			       in ->
				   in_state_change(Item#roster.subscription,
						   Item#roster.ask,
						   Type)
			   end,
		AutoReply = case Direction of
				out ->
				    none;
				in ->
				    in_auto_reply(Item#roster.subscription,
						  Item#roster.ask,
						  Type)
			    end,
		AskMessage = case NewState of
				 {_, both} -> Reason;
				 {_, in}   -> Reason;
				 _         -> ""
			     end,
		case NewState of
		    none ->
			{none, AutoReply};
		    {none, none} when Item#roster.subscription == none,
		                      Item#roster.ask == in ->
                        del_roster_t(LUser, LServer, LJID),
			{none, AutoReply};
		    {Subscription, Pending} ->
			NewItem = Item#roster{subscription = Subscription,
					      ask = Pending,
					      askmessage = list_to_binary(AskMessage)},
                        roster_subscribe_t(LUser, LServer, LJID, NewItem),
			case roster_version_on_db(LServer) of
                            true -> write_roster_version_t(LUser, LServer);
                            false -> ok
			end,
			{{push, NewItem}, AutoReply}
		end
	end,
    case transaction(LServer, F) of
	{atomic, {Push, AutoReply}} ->
	    case AutoReply of
		none ->
		    ok;
		_ ->
		    T = case AutoReply of
			    subscribed -> "subscribed";
			    unsubscribed -> "unsubscribed"
			end,
		    ejabberd_router:route(
		      jlib:make_jid(User, Server, ""), JID1,
		      {xmlelement, "presence", [{"type", T}], []})
	    end,
	    case Push of
		{push, Item} ->
		    if
			Item#roster.subscription == none,
			Item#roster.ask == in ->
			    ok;
			true ->
			    push_item(User, Server,
				      jlib:make_jid(User, Server, ""), Item)
		    end,
		    true;
		none ->
		    false
	    end;
	_ ->
	    false
    end.

%% in_state_change(Subscription, Pending, Type) -> NewState
%% NewState = none | {NewSubscription, NewPending}
-ifdef(ROSTER_GATEWAY_WORKAROUND).
-define(NNSD, {to, none}).
-define(NISD, {to, in}).
-else.
-define(NNSD, none).
-define(NISD, none).
-endif.

in_state_change(none, none, subscribe)    -> {none, in};
in_state_change(none, none, subscribed)   -> ?NNSD;
in_state_change(none, none, unsubscribe)  -> none;
in_state_change(none, none, unsubscribed) -> none;
in_state_change(none, out,  subscribe)    -> {none, both};
in_state_change(none, out,  subscribed)   -> {to, none};
in_state_change(none, out,  unsubscribe)  -> none;
in_state_change(none, out,  unsubscribed) -> {none, none};
in_state_change(none, in,   subscribe)    -> none;
in_state_change(none, in,   subscribed)   -> ?NISD;
in_state_change(none, in,   unsubscribe)  -> {none, none};
in_state_change(none, in,   unsubscribed) -> none;
in_state_change(none, both, subscribe)    -> none;
in_state_change(none, both, subscribed)   -> {to, in};
in_state_change(none, both, unsubscribe)  -> {none, out};
in_state_change(none, both, unsubscribed) -> {none, in};
in_state_change(to,   none, subscribe)    -> {to, in};
in_state_change(to,   none, subscribed)   -> none;
in_state_change(to,   none, unsubscribe)  -> none;
in_state_change(to,   none, unsubscribed) -> {none, none};
in_state_change(to,   in,   subscribe)    -> none;
in_state_change(to,   in,   subscribed)   -> none;
in_state_change(to,   in,   unsubscribe)  -> {to, none};
in_state_change(to,   in,   unsubscribed) -> {none, in};
in_state_change(from, none, subscribe)    -> none;
in_state_change(from, none, subscribed)   -> {both, none};
in_state_change(from, none, unsubscribe)  -> {none, none};
in_state_change(from, none, unsubscribed) -> none;
in_state_change(from, out,  subscribe)    -> none;
in_state_change(from, out,  subscribed)   -> {both, none};
in_state_change(from, out,  unsubscribe)  -> {none, out};
in_state_change(from, out,  unsubscribed) -> {from, none};
in_state_change(both, none, subscribe)    -> none;
in_state_change(both, none, subscribed)   -> none;
in_state_change(both, none, unsubscribe)  -> {to, none};
in_state_change(both, none, unsubscribed) -> {from, none}.

out_state_change(none, none, subscribe)    -> {none, out};
out_state_change(none, none, subscribed)   -> none;
out_state_change(none, none, unsubscribe)  -> none;
out_state_change(none, none, unsubscribed) -> none;
out_state_change(none, out,  subscribe)    -> {none, out}; %% We need to resend query (RFC3921, section 9.2)
out_state_change(none, out,  subscribed)   -> none;
out_state_change(none, out,  unsubscribe)  -> {none, none};
out_state_change(none, out,  unsubscribed) -> none;
out_state_change(none, in,   subscribe)    -> {none, both};
out_state_change(none, in,   subscribed)   -> {from, none};
out_state_change(none, in,   unsubscribe)  -> none;
out_state_change(none, in,   unsubscribed) -> {none, none};
out_state_change(none, both, subscribe)    -> none;
out_state_change(none, both, subscribed)   -> {from, out};
out_state_change(none, both, unsubscribe)  -> {none, in};
out_state_change(none, both, unsubscribed) -> {none, out};
out_state_change(to,   none, subscribe)    -> none;
out_state_change(to,   none, subscribed)   -> {both, none};
out_state_change(to,   none, unsubscribe)  -> {none, none};
out_state_change(to,   none, unsubscribed) -> none;
out_state_change(to,   in,   subscribe)    -> none;
out_state_change(to,   in,   subscribed)   -> {both, none};
out_state_change(to,   in,   unsubscribe)  -> {none, in};
out_state_change(to,   in,   unsubscribed) -> {to, none};
out_state_change(from, none, subscribe)    -> {from, out};
out_state_change(from, none, subscribed)   -> none;
out_state_change(from, none, unsubscribe)  -> none;
out_state_change(from, none, unsubscribed) -> {none, none};
out_state_change(from, out,  subscribe)    -> none;
out_state_change(from, out,  subscribed)   -> none;
out_state_change(from, out,  unsubscribe)  -> {from, none};
out_state_change(from, out,  unsubscribed) -> {none, out};
out_state_change(both, none, subscribe)    -> none;
out_state_change(both, none, subscribed)   -> none;
out_state_change(both, none, unsubscribe)  -> {from, none};
out_state_change(both, none, unsubscribed) -> {to, none}.

in_auto_reply(from, none, subscribe)    -> subscribed;
in_auto_reply(from, out,  subscribe)    -> subscribed;
in_auto_reply(both, none, subscribe)    -> subscribed;
in_auto_reply(none, in,   unsubscribe)  -> unsubscribed;
in_auto_reply(none, both, unsubscribe)  -> unsubscribed;
in_auto_reply(to,   in,   unsubscribe)  -> unsubscribed;
in_auto_reply(from, none, unsubscribe)  -> unsubscribed;
in_auto_reply(from, out,  unsubscribe)  -> unsubscribed;
in_auto_reply(both, none, unsubscribe)  -> unsubscribed;
in_auto_reply(_,    _,    _)  ->           none.


remove_user(User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    remove_user(LUser, LServer, gen_mod:db_type(LServer, ?MODULE)).

remove_user(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    send_unsubscription_to_rosteritems(LUser, LServer),
    F = fun() ->
		lists:foreach(fun(R) ->
				      mnesia:delete_object(R)
			      end,
			      mnesia:index_read(roster, US, #roster.us))
        end,
    mnesia:transaction(F);
remove_user(LUser, LServer, redis) ->
    Redis_host = redis_host(LServer),
    Redis_port = redis_port(LServer),
    Redis_database = redis_database(LServer),
    Redis_password = redis_password(LServer),
    {ok, C} = case Redis_password of
                none -> eredis:start_link(Redis_host, Redis_port, Redis_database, no_dbselection);
                _ -> eredis:start_link(Redis_host, Redis_port, Redis_database, Redis_password, no_dbselection)
              end,
    eredis:q(C, ["DEL", "rosterusers::" ++ LUser ]),
    send_unsubscription_to_rosteritems(LUser, LServer),
    ok;
remove_user(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    send_unsubscription_to_rosteritems(LUser, LServer),
    odbc_queries:del_user_roster_t(LServer, Username),
    ok.

%% For each contact with Subscription:
%% Both or From, send a "unsubscribed" presence stanza;
%% Both or To, send a "unsubscribe" presence stanza.
send_unsubscription_to_rosteritems(LUser, LServer) ->
    RosterItems = get_user_roster([], {LUser, LServer}),
    From = jlib:make_jid({LUser, LServer, ""}),
    lists:foreach(fun(RosterItem) ->
			  send_unsubscribing_presence(From, RosterItem)
		  end,
		  RosterItems).

%% @spec (From::jid(), Item::roster()) -> ok
send_unsubscribing_presence(From, Item) ->
    IsTo = case Item#roster.subscription of
	       both -> true;
	       to -> true;
	       _ -> false
	   end,
    IsFrom = case Item#roster.subscription of
		 both -> true;
		 from -> true;
		 _ -> false
	     end,
    if IsTo ->
	    send_presence_type(
	      jlib:jid_remove_resource(From),
	      jlib:make_jid(Item#roster.jid), "unsubscribe");
       true -> ok
    end,
    if IsFrom ->
	    send_presence_type(
	      jlib:jid_remove_resource(From),
	      jlib:make_jid(Item#roster.jid), "unsubscribed");
       true -> ok
    end,
    ok.

send_presence_type(From, To, Type) ->
    ejabberd_router:route(
      From, To,
      {xmlelement, "presence",
       [{"type", Type}],
       []}).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

set_items(User, Server, SubEl) ->
    {xmlelement, _Name, _Attrs, Els} = SubEl,
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    F = fun() ->
                lists:foreach(
                  fun(El) ->
                          process_item_set_t(LUser, LServer, El)
                  end, Els)
        end,
    transaction(LServer, F).

update_roster_t(LUser, LServer, LJID, Item) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    update_roster_t(LUser, LServer, LJID, Item, DBType).

update_roster_t(_LUser, _LServer, _LJID, Item, mnesia) ->
    mnesia:write(Item);
update_roster_t(LUser, LServer, LJID, Item, redis) ->
    {RUser, RServer, _} = LJID,
    NewRosterRedis = redis_make_record_from_roster_user(LUser, Item),
    Redis_host = redis_host(LServer),
    Redis_port = redis_port(LServer),
    Redis_database = redis_database(LServer),
    Redis_password = redis_password(LServer),
    {ok, C} = case Redis_password of
                none -> eredis:start_link(Redis_host, Redis_port, Redis_database, no_dbselection);
                _ -> eredis:start_link(Redis_host, Redis_port, Redis_database, Redis_password, no_dbselection)
              end,
    eredis:q(C, ["HSET", "rosterusers::" ++ LUser, RUser ++ "@" ++ RServer, NewRosterRedis]),
    ok;
update_roster_t(LUser, LServer, LJID, Item, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    ItemVals = record_to_string(Item),
    ItemGroups = groups_to_string(Item),
    odbc_queries:update_roster(LServer, Username, SJID, ItemVals, ItemGroups).

del_roster_t(LUser, LServer, LJID) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    del_roster_t(LUser, LServer, LJID, DBType).

del_roster_t(LUser, LServer, LJID, mnesia) ->
    mnesia:delete({roster, {LUser, LServer, LJID}});
del_roster_t(LUser, LServer, LJID, redis) ->
    {RUser, RServer, _} = LJID,
    Redis_host = redis_host(LServer),
    Redis_port = redis_port(LServer),
    Redis_database = redis_database(LServer),
    Redis_password = redis_password(LServer),
    {ok, C} = case Redis_password of
                none -> eredis:start_link(Redis_host, Redis_port, Redis_database, no_dbselection);
                _ -> eredis:start_link(Redis_host, Redis_port, Redis_database, Redis_password, no_dbselection)
              end,
    eredis:q(C, ["HDEL", "rosterusers::" ++ LUser, RUser ++ "@" ++ RServer]),
    ok;
del_roster_t(LUser, LServer, LJID, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    odbc_queries:del_roster(LServer, Username, SJID).

process_item_set_t(LUser, LServer, {xmlelement, _Name, Attrs, Els}) ->
    JID1 = jlib:string_to_jid(xml:get_attr_s("jid", Attrs)),
    case JID1 of
	error ->
	    ok;
	_ ->
	    JID = {JID1#jid.user, JID1#jid.server, JID1#jid.resource},
	    LJID = {JID1#jid.luser, JID1#jid.lserver, JID1#jid.lresource},
	    Item = #roster{usj = {LUser, LServer, LJID},
			   us = {LUser, LServer},
			   jid = JID},
	    Item1 = process_item_attrs_ws(Item, Attrs),
	    Item2 = process_item_els(Item1, Els),
            case Item2#roster.subscription of
                remove ->
                    del_roster_t(LUser, LServer, LJID);
                _ ->
                    update_roster_t(LUser, LServer, LJID, Item2)
            end
    end;
process_item_set_t(_LUser, _LServer, _) ->
    ok.

process_item_attrs_ws(Item, [{Attr, Val} | Attrs]) ->
    case Attr of
	"jid" ->
	    case jlib:string_to_jid(Val) of
		error ->
		    process_item_attrs_ws(Item, Attrs);
		JID1 ->
		    JID = {JID1#jid.luser, JID1#jid.lserver, JID1#jid.lresource},
		    process_item_attrs_ws(Item#roster{jid = JID}, Attrs)
	    end;
	"name" ->
	    process_item_attrs_ws(Item#roster{name = Val}, Attrs);
	"subscription" ->
	    case Val of
		"remove" ->
		    process_item_attrs_ws(Item#roster{subscription = remove},
					  Attrs);
		"none" ->
		    process_item_attrs_ws(Item#roster{subscription = none},
					  Attrs);
		"both" ->
		    process_item_attrs_ws(Item#roster{subscription = both},
					  Attrs);
		"from" ->
		    process_item_attrs_ws(Item#roster{subscription = from},
					  Attrs);
		"to" ->
		    process_item_attrs_ws(Item#roster{subscription = to},
					  Attrs);
		_ ->
		    process_item_attrs_ws(Item, Attrs)
	    end;
	"ask" ->
	    process_item_attrs_ws(Item, Attrs);
	_ ->
	    process_item_attrs_ws(Item, Attrs)
    end;
process_item_attrs_ws(Item, []) ->
    Item.

get_in_pending_subscriptions(Ls, User, Server) ->
    LServer = jlib:nameprep(Server),
    get_in_pending_subscriptions(Ls, User, Server,
                                 gen_mod:db_type(LServer, ?MODULE)).

get_in_pending_subscriptions(Ls, User, Server, mnesia) ->
    JID = jlib:make_jid(User, Server, ""),
    US = {JID#jid.luser, JID#jid.lserver},
    case mnesia:dirty_index_read(roster, US, #roster.us) of
	Result when is_list(Result) ->
    	    Ls ++ lists:map(
		    fun(R) ->
			    Message = R#roster.askmessage,
			    Status  = if is_binary(Message) ->
					      binary_to_list(Message);
					 true ->
					      ""
				      end,
			    {xmlelement, "presence",
			     [{"from", jlib:jid_to_string(R#roster.jid)},
			      {"to", jlib:jid_to_string(JID)},
			      {"type", "subscribe"}],
			     [{xmlelement, "status", [],
			       [{xmlcdata, Status}]}]}
		    end,
		    lists:filter(
		      fun(R) ->
			      case R#roster.ask of
				  in   -> true;
				  both -> true;
				  _ -> false
			      end
		      end,
		      Result));
	_ ->
	    Ls
    end;
get_in_pending_subscriptions(Ls, User, Server, redis) ->
    % TODO: must be implemented
    JID = jlib:make_jid(User, Server, ""),
    case get_roster(User, Server, redis) of
    [] -> Ls;
    Result -> 
    	    Ls ++ lists:map(
		    fun(R) ->
			    Message = R#roster.askmessage,
			    Status  = if is_binary(Message) ->
					      binary_to_list(Message);
					 true ->
					      ""
				      end,
			    {xmlelement, "presence",
			     [{"from", jlib:jid_to_string(R#roster.jid)},
			      {"to", jlib:jid_to_string(JID)},
			      {"type", "subscribe"}],
			     [{xmlelement, "status", [],
			       [{xmlcdata, Status}]}]}
		    end,
		    lists:filter(
		      fun(R) ->
			      case R#roster.ask of
				  in   -> true;
				  both -> true;
				  _ -> false
			      end
		      end,
		      Result))
    end;
get_in_pending_subscriptions(Ls, User, Server, odbc) ->
    JID = jlib:make_jid(User, Server, ""),
    LUser = JID#jid.luser,
    LServer = JID#jid.lserver,
    Username = ejabberd_odbc:escape(LUser),
    case catch odbc_queries:get_roster(LServer, Username) of
	{selected, ["username", "jid", "nick", "subscription", "ask",
		    "askmessage", "server", "subscribe", "type"],
	 Items} when is_list(Items) ->
    	    Ls ++ lists:map(
		    fun(R) ->
			    Message = R#roster.askmessage,
			    {xmlelement, "presence",
			     [{"from", jlib:jid_to_string(R#roster.jid)},
			      {"to", jlib:jid_to_string(JID)},
			      {"type", "subscribe"}],
			     [{xmlelement, "status", [],
			       [{xmlcdata, Message}]}]}
		    end,
		    lists:flatmap(
		      fun(I) ->
			      case raw_to_record(LServer, I) of
				  %% Bad JID in database:
				  error ->
				      [];
				  R ->
				      case R#roster.ask of
					  in   -> [R];
					  both -> [R];
					  _ -> []
				      end
			      end
		      end,
		      Items));
	_ ->
	    Ls
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

read_subscription_and_groups(User, Server, LJID) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    read_subscription_and_groups(LUser, LServer, LJID,
                                 gen_mod:db_type(LServer, ?MODULE)).

read_subscription_and_groups(LUser, LServer, LJID, mnesia) ->
    case catch mnesia:dirty_read(roster, {LUser, LServer, LJID}) of
	[#roster{subscription = Subscription, groups = Groups}] ->
	    {Subscription, Groups};
        _ ->
            error
    end;
read_subscription_and_groups(LUser, LServer, LJID, redis) ->
    Entries = get_roster(LUser, LServer, redis),
    case [Entry || Entry <- Entries, Entry#roster.jid == LJID] of
        [] -> error;
        [R] -> {R#roster.subscription, R#roster.groups}
    end;
read_subscription_and_groups(LUser, LServer, LJID, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    case catch odbc_queries:get_subscription(LServer, Username, SJID) of
	{selected, ["subscription"], [{SSubscription}]} ->
	    Subscription = case SSubscription of
			       "B" -> both;
			       "T" -> to;
			       "F" -> from;
			       _ -> none
			   end,
	    Groups = case catch odbc_queries:get_rostergroup_by_jid(
                                  LServer, Username, SJID) of
			 {selected, ["grp"], JGrps} when is_list(JGrps) ->
			     [JGrp || {JGrp} <- JGrps];
			 _ ->
			     []
		     end,
	    {Subscription, Groups};
        _ ->
            error
    end.

get_jid_info(_, User, Server, JID) ->
    LJID = jlib:jid_tolower(JID),
    case read_subscription_and_groups(User, Server, LJID) of
        {Subscription, Groups} ->
            {Subscription, Groups};
        error ->
	    LRJID = jlib:jid_tolower(jlib:jid_remove_resource(JID)),
    if
    LRJID == LJID ->
		    {none, []};
		true ->
                    case read_subscription_and_groups(
                           User, Server, LRJID) of
                        {Subscription, Groups} ->
			    {Subscription, Groups};
			error ->
			    {none, []}
		    end
	    end
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

raw_to_record(LServer, {User, SJID, Nick, SSubscription, SAsk, SAskMessage,
			_SServer, _SSubscribe, _SType}) ->
    case jlib:string_to_jid(SJID) of
	error ->
	    error;
	JID ->
	    LJID = jlib:jid_tolower(JID),
	    Subscription = case SSubscription of
			       "B" -> both;
			       "T" -> to;
			       "F" -> from;
			       _ -> none
			   end,
	    Ask = case SAsk of
		      "S" -> subscribe;
		      "U" -> unsubscribe;
		      "B" -> both;
		      "O" -> out;
		      "I" -> in;
		      _ -> none
		  end,
	    #roster{usj = {User, LServer, LJID},
		    us = {User, LServer},
		    jid = LJID,
		    name = Nick,
		    subscription = Subscription,
		    ask = Ask,
		    askmessage = SAskMessage}
    end.

record_to_string(#roster{us = {User, _Server},
			 jid = JID,
			 name = Name,
			 subscription = Subscription,
			 ask = Ask,
			 askmessage = AskMessage}) ->
    Username = ejabberd_odbc:escape(User),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(jlib:jid_tolower(JID))),
    Nick = ejabberd_odbc:escape(Name),
    SSubscription = case Subscription of
			both -> "B";
			to   -> "T";
			from -> "F";
			none -> "N"
		    end,
    SAsk = case Ask of
	       subscribe   -> "S";
	       unsubscribe -> "U";
	       both	   -> "B";
	       out	   -> "O";
	       in	   -> "I";
	       none	   -> "N"
	   end,
    SAskMessage = ejabberd_odbc:escape(AskMessage),
    [Username, SJID, Nick, SSubscription, SAsk, SAskMessage, "N", "", "item"].

groups_to_string(#roster{us = {User, _Server},
			 jid = JID,
			 groups = Groups}) ->
    Username = ejabberd_odbc:escape(User),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(jlib:jid_tolower(JID))),

    %% Empty groups do not need to be converted to string to be inserted in
    %% the database
    lists:foldl(
      fun([], Acc) -> Acc;
	 (Group, Acc) ->
 	      G = ejabberd_odbc:escape(Group),
	      [[Username, SJID, G]|Acc] end, [], Groups).

update_table() ->
    Fields = record_info(fields, roster),
    case mnesia:table_info(roster, attributes) of
	Fields ->
	    ok;
	[uj, user, jid, name, subscription, ask, groups, xattrs, xs] ->
	    convert_table1(Fields);
	[usj, us, jid, name, subscription, ask, groups, xattrs, xs] ->
	    convert_table2(Fields);
	_ ->
	    ?INFO_MSG("Recreating roster table", []),
	    mnesia:transform_table(roster, ignore, Fields)
    end.


%% Convert roster table to support virtual host
convert_table1(Fields) ->
    ?INFO_MSG("Virtual host support: converting roster table from "
	      "{uj, user, jid, name, subscription, ask, groups, xattrs, xs} format", []),
    Host = ?MYNAME,
    {atomic, ok} = mnesia:create_table(
		     mod_roster_tmp_table,
		     [{disc_only_copies, [node()]},
		      {type, bag},
		      {local_content, true},
		      {record_name, roster},
		      {attributes, record_info(fields, roster)}]),
    mnesia:del_table_index(roster, user),
    mnesia:transform_table(roster, ignore, Fields),
    F1 = fun() ->
		 mnesia:write_lock_table(mod_roster_tmp_table),
		 mnesia:foldl(
		   fun(#roster{usj = {U, JID}, us = U} = R, _) ->
			   mnesia:dirty_write(
			     mod_roster_tmp_table,
			     R#roster{usj = {U, Host, JID},
				      us = {U, Host}})
		   end, ok, roster)
	 end,
    mnesia:transaction(F1),
    mnesia:clear_table(roster),
    F2 = fun() ->
		 mnesia:write_lock_table(roster),
		 mnesia:foldl(
		   fun(R, _) ->
			   mnesia:dirty_write(R)
		   end, ok, mod_roster_tmp_table)
	 end,
    mnesia:transaction(F2),
    mnesia:delete_table(mod_roster_tmp_table).


%% Convert roster table: xattrs fields become 
convert_table2(Fields) ->
    ?INFO_MSG("Converting roster table from "
	      "{usj, us, jid, name, subscription, ask, groups, xattrs, xs} format", []),
    mnesia:transform_table(roster, ignore, Fields).


webadmin_page(_, Host,
	      #request{us = _US,
		       path = ["user", U, "roster"],
		       q = Query,
		       lang = Lang} = _Request) ->
    Res = user_roster(U, Host, Query, Lang),
    {stop, Res};

webadmin_page(Acc, _, _) -> Acc.

user_roster(User, Server, Query, Lang) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    US = {LUser, LServer},
    Items1 = get_roster(LUser, LServer),
    Res = user_roster_parse_query(User, Server, Items1, Query),
    Items = get_roster(LUser, LServer),
    SItems = lists:sort(Items),
    FItems =
	case SItems of
	    [] ->
		[?CT("None")];
	    _ ->
		[?XE("table",
		     [?XE("thead",
			  [?XE("tr",
			       [?XCT("td", "Jabber ID"),
				?XCT("td", "Nickname"),
				?XCT("td", "Subscription"),
				?XCT("td", "Pending"),
				?XCT("td", "Groups")
			       ])]),
		      ?XE("tbody",
			  lists:map(
			    fun(R) ->
				    Groups =
					lists:flatmap(
					  fun(Group) ->
						  [?C(Group), ?BR]
					  end, R#roster.groups),
				    Pending = ask_to_pending(R#roster.ask),
				    TDJID = build_contact_jid_td(R#roster.jid),
				    ?XE("tr",
					[TDJID,
					 ?XAC("td", [{"class", "valign"}],
					      R#roster.name),
					 ?XAC("td", [{"class", "valign"}],
					      atom_to_list(R#roster.subscription)),
					 ?XAC("td", [{"class", "valign"}],
					      atom_to_list(Pending)),
					 ?XAE("td", [{"class", "valign"}], Groups),
					 if
					     Pending == in ->
						 ?XAE("td", [{"class", "valign"}],
						      [?INPUTT("submit",
							       "validate" ++
							       ejabberd_web_admin:term_to_id(R#roster.jid),
							       "Validate")]);
					     true ->
						 ?X("td")
					 end,
					 ?XAE("td", [{"class", "valign"}],
					      [?INPUTT("submit",
						       "remove" ++
						       ejabberd_web_admin:term_to_id(R#roster.jid),
						       "Remove")])])
			    end, SItems))])]
	end,
    [?XC("h1", ?T("Roster of ") ++ us_to_list(US))] ++
	case Res of
	    ok -> [?XREST("Submitted")];
	    error -> [?XREST("Bad format")];
	    nothing -> []
	end ++
	[?XAE("form", [{"action", ""}, {"method", "post"}],
	      FItems ++
	      [?P,
	       ?INPUT("text", "newjid", ""), ?C(" "),
	       ?INPUTT("submit", "addjid", "Add Jabber ID")
	      ])].

build_contact_jid_td(RosterJID) ->
    %% Convert {U, S, R} into {jid, U, S, R, U, S, R}:
    ContactJID = jlib:make_jid(RosterJID),
    JIDURI = case {ContactJID#jid.luser, ContactJID#jid.lserver} of
		 {"", _} -> "";
		 {CUser, CServer} ->
		     case lists:member(CServer, ?MYHOSTS) of
			 false -> "";
			 true -> "/admin/server/" ++ CServer ++ "/user/" ++ CUser ++ "/"
		     end
	     end,
    case JIDURI of
	[] ->
	    ?XAC("td", [{"class", "valign"}], jlib:jid_to_string(RosterJID));
	URI when is_list(URI) ->
	    ?XAE("td", [{"class", "valign"}], [?AC(JIDURI, jlib:jid_to_string(RosterJID))])
    end.

user_roster_parse_query(User, Server, Items, Query) ->
    case lists:keysearch("addjid", 1, Query) of
	{value, _} ->
	    case lists:keysearch("newjid", 1, Query) of
		{value, {_, undefined}} ->
		    error;
		{value, {_, SJID}} ->
		    case jlib:string_to_jid(SJID) of
			JID when is_record(JID, jid) ->
			    user_roster_subscribe_jid(User, Server, JID),
			    ok;
			error ->
			    error
		    end;
		false ->
		    error
	    end;
	false ->
	    case catch user_roster_item_parse_query(
			 User, Server, Items, Query) of
		submitted ->
		    ok;
		{'EXIT', _Reason} ->
		    error;
		_ ->
		    nothing
	    end
    end.


user_roster_subscribe_jid(User, Server, JID) ->
    out_subscription(User, Server, JID, subscribe),
    UJID = jlib:make_jid(User, Server, ""),
    ejabberd_router:route(
      UJID, JID, {xmlelement, "presence", [{"type", "subscribe"}], []}).

user_roster_item_parse_query(User, Server, Items, Query) ->
    lists:foreach(
      fun(R) ->
	      JID = R#roster.jid,
	      case lists:keysearch(
		     "validate" ++ ejabberd_web_admin:term_to_id(JID), 1, Query) of
		  {value, _} ->
		      JID1 = jlib:make_jid(JID),
		      out_subscription(
			User, Server, JID1, subscribed),
		      UJID = jlib:make_jid(User, Server, ""),
		      ejabberd_router:route(
			UJID, JID1, {xmlelement, "presence",
				     [{"type", "subscribed"}], []}),
		      throw(submitted);
		  false ->
		      case lists:keysearch(
			     "remove" ++ ejabberd_web_admin:term_to_id(JID), 1, Query) of
			  {value, _} ->
			      UJID = jlib:make_jid(User, Server, ""),
			      process_iq(
				UJID, UJID,
				#iq{type = set,
				    sub_el = {xmlelement, "query",
					      [{"xmlns", ?NS_ROSTER}],
					      [{xmlelement, "item",
						[{"jid", jlib:jid_to_string(JID)},
						 {"subscription", "remove"}],
						[]}]}}),
			      throw(submitted);
			  false ->
			      ok
		      end

	      end
      end, Items),
    nothing.

us_to_list({User, Server}) ->
    jlib:jid_to_string({User, Server, ""}).

webadmin_user(Acc, _User, _Server, Lang) ->
    Acc ++ [?XE("h3", [?ACT("roster/", "Roster")])].

%% redis

redis_make_record_from_roster_user(_User, Item) ->
    %{RUser, RServer, _} = Item#roster.jid,
    Name = Item#roster.name,
    Subscription = redis_subscription_to_string(Item#roster.subscription),
    Ask = redis_ask_to_string(Item#roster.ask),
    AskMessage = redis_askmessage_to_string(Item#roster.askmessage),
    Groups =
        case Item#roster.groups of
            [Grp] when is_list(Grp) -> Grp;
            Grps when is_list(Grps) -> string:join(Grps, ",");
            [] -> ""
        end,
    RosterEntry = Name ++ "::" ++ Subscription ++ "::" ++ Ask ++ "::" ++ AskMessage ++ "::" ++ Groups,
    RosterEntry.

%redis_make_roster_record(User, [HdEntry | TlEntries] ) ->
%    redis_make_roster_record(User, TlEntries, redis_make_record_from_roster_user(User, HdEntry)).
%
%redis_make_roster_record(User, [HdEntry | TlEntries], Acc ) ->
%    redis_make_roster_record(User, TlEntries, Acc ++ "||" ++ redis_make_record_from_roster_user(User, HdEntry));
%redis_make_roster_record(_User, [], Acc ) -> Acc.

redis_update_roster([HdEntry | TlEntries], {Name, NewRosterEntry}) ->
    case HdEntry#roster.name of
        Name -> 
            redis_update_roster(TlEntries, {Name, NewRosterEntry}, NewRosterEntry);
        _ ->
            redis_update_roster(TlEntries, {Name, NewRosterEntry}, redis_make_record_from_roster_user( none, HdEntry))
    end;
redis_update_roster([], {_Name, NewRosterEntry}) -> NewRosterEntry.

redis_update_roster([HdEntry | TlEntries], {Name, NewRosterEntry}, RosterAcc) ->
    case HdEntry#roster.name of
        Name -> 
            redis_update_roster(TlEntries, {Name, NewRosterEntry}, RosterAcc ++ "||" ++ NewRosterEntry);
        _ ->
            redis_update_roster(TlEntries, {Name, NewRosterEntry}, RosterAcc ++ "||" ++ redis_make_record_from_roster_user( none, HdEntry))
    end;
redis_update_roster([], {_Name, _NewRosterEntry}, RosterAcc) -> RosterAcc.

%redis_make_roster_user_from_record( User, Server, RUser, RServer, BEntry ) when is_binary(BEntry)->
%    redis_make_roster_user_from_record( User, Server, RUser, RServer, binary_to_list(BEntry) );
redis_make_roster_user_from_record( User, Server, RUser, RServer, Entry ) ->
    [ Name, Subscription, Ask, AskMessage, Group] = re:split( Entry, "::", [{return,list}]),
    JID = {RUser, RServer, []},
    #roster{ usj={User, Server, JID}, us={User, Server}, 
             jid=JID, 
             name=Name, 
             subscription=redis_subscription_to_atom(Subscription), 
             ask=redis_ask_to_atom(Ask), 
             askmessage=AskMessage, 
             groups=[Group], 
             xs=[] }.

redis_make_roster_user( User, Server, [ {Contact, Infos} | TlKeys] ) ->
    [RUser, RServer] = re:split( Contact, "@", [{return,list}] ),
    R = redis_make_roster_user_from_record( User, Server, RUser, RServer, Infos ),
    redis_make_roster_user( User, Server, TlKeys, [R]);
redis_make_roster_user( _User, _Server, []) -> [].

redis_make_roster_user( User, Server, [ {Contact, Infos} | TlKeys], Acc ) ->
    [RUser, RServer] = re:split( Contact, "@", [{return,list}] ),
    R = redis_make_roster_user_from_record( User, Server, RUser, RServer, Infos ),
    redis_make_roster_user( User, Server, TlKeys, Acc ++ [R]);
redis_make_roster_user( _USer, _Server, [], Acc) -> Acc.

redis_make_list_entries([HdKey | Tl]) ->
    HdValue = hd(Tl),
    Entry = {binary_to_list(HdKey), binary_to_list(HdValue)},
    redis_make_list_entries(lists:delete(HdValue, Tl), [Entry]);
redis_make_list_entries([]) -> [].

redis_make_list_entries([HdKey | Tl], Acc) ->
    HdValue = hd(Tl),
    Entry = {binary_to_list(HdKey), binary_to_list(HdValue)},
    redis_make_list_entries(lists:delete(HdValue, Tl), Acc ++ [Entry]);
redis_make_list_entries([], Acc) -> Acc.
  

redis_subscription_to_string(from)   -> "F";
redis_subscription_to_string(to)     -> "T";
redis_subscription_to_string(both)   -> "B";
redis_subscription_to_string(_)      -> "".

redis_subscription_to_atom("F") -> from;
redis_subscription_to_atom("T") -> to;
redis_subscription_to_atom("B") -> both;
redis_subscription_to_atom(_)   -> none.

redis_ask_to_string(subscribe)   -> "S";
redis_ask_to_string(unsubscribe) -> "U";
redis_ask_to_string(both)        -> "B";
redis_ask_to_string(out)         -> "O";
redis_ask_to_string(in)          -> "I";
redis_ask_to_string(none)        -> "".

redis_ask_to_atom("S") -> subscribe;
redis_ask_to_atom("U") -> unsubscribe;
redis_ask_to_atom("B") -> both;
redis_ask_to_atom("O") -> out;
redis_ask_to_atom("I") -> in;
redis_ask_to_atom(_)   -> none.

redis_askmessage_to_string(BAskMessage) when is_binary(BAskMessage)  -> binary_to_list(BAskMessage);
redis_askmessage_to_string(AskMessage) when is_list(AskMessage)  -> AskMessage.

redis_filter_keys([HdKey | TlKeys]) ->
    K = re:split( binary_to_list(HdKey), " ",[{return,list}]),
    redis_filter_keys(TlKeys, [hd(K)]).
redis_filter_keys([HdKey | TlKeys], Acc) -> 
    K = re:split( binary_to_list(HdKey), " ",[{return,list}]),
    case lists:member( hd(K), Acc) of
        true -> redis_filter_keys(TlKeys, Acc);
        _ -> redis_filter_keys(TlKeys, Acc ++ [hd(K)])
    end;
redis_filter_keys([], Acc) -> Acc.

redis_host(Host) ->
  gen_mod:get_module_opt(Host, ?MODULE, redis_host, "127.0.0.1").

redis_port(Host) ->
  gen_mod:get_module_opt(Host, ?MODULE, redis_port, 6379).

redis_database(Host) ->
  gen_mod:get_module_opt(Host, ?MODULE, redis_database, 0).

redis_reconnect_sleep(Host) ->
  gen_mod:get_module_opt(Host, ?MODULE, reconnect_sleep, 100).

redis_password(Host) ->
  gen_mod:get_module_opt(Host, ?MODULE, redis_password, none).

