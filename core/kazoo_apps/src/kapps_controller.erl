%%%-------------------------------------------------------------------
%%% @copyright (C) 2010-2016, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%   Karl Anderson
%%%-------------------------------------------------------------------
-module(kapps_controller).

%% API
-export([start_link/0
        ,start_app/1
        ,start_default_apps/0
        ,stop_app/1
        ,restart_app/1
        ,running_apps/0, running_apps/1
        ,list_apps/0
        ]).

-include("kazoo_apps.hrl").

-define(HIDDEN_APPS
       ,['amqp_client'
        ,'apns'
        ,'asn1'
        ,'bear'
        ,'braintree'
        ,'certifi'
        ,'compiler'
        ,'couchbeam'
        ,'cowboy'
        ,'cowlib'
        ,'crypto'
        ,'eflame'
        ,'escalus'
        ,'exml'
        ,'folsom'
        ,'gcm'
        ,'gen_smtp'
        ,'goldrush'
        ,'gproc'
        ,'hackney'
        ,'idna'
        ,'inets'
        ,'kazoo'
        ,'kazoo_amqp'
        ,'kazoo_apps'
        ,'kazoo_bindings'
        ,'kazoo_caches'
        ,'kazoo_config'
        ,'kazoo_couch'
        ,'kazoo_data'
        ,'kazoo_documents'
        ,'kazoo_endpoint'
        ,'kazoo_etsmgr'
        ,'kazoo_globals'
        ,'kazoo_media'
        ,'kazoo_modb'
        ,'kazoo_number_manager'
        ,'kazoo_oauth'
        ,'kazoo_services'
        ,'kazoo_stats'
        ,'kazoo_token_buckets'
        ,'kazoo_transactions'
        ,'kazoo_voicemail'
        ,'kazoo_web'
        ,'kazoo_xml'
        ,'kernel'
        ,'lager'
        ,'lager_syslog'
        ,'mimerl'
        ,'nksip'
        ,'poolboy'
        ,'public_key'
        ,'rabbit_common'
        ,'ranch'
        ,'sasl'
        ,'ssl'
        ,'stdlib'
        ,'syntax_tools'
        ,'syslog'
        ,'tasks'
        ,'webseq'
        ,'xmerl'
        ,'zucchini'
        ]).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc Starts the server
%%--------------------------------------------------------------------
-spec start_link() -> startlink_ret().
start_link() ->
    _ = kz_util:spawn(fun initialize_kapps/0),
    'ignore'.

-spec start_default_apps() -> [{atom(), 'ok' | {'error', any()}}].
start_default_apps() ->
    [{App, start_app(App)} || App <- ?DEFAULT_KAPPS].

-spec start_app(atom() | nonempty_string() | ne_binary()) -> 'ok' | {'error', any()}.
start_app(App) when is_atom(App) ->
    case application:ensure_all_started(App) of
        {'ok', _}=OK -> OK;
        {'error', _E}=E ->
            lager:error("~s could not start: ~p", [App, _E]),
            E
    end;
start_app(App) ->
    start_app(kz_util:to_atom(App, 'true')).

-spec stop_app(atom() | nonempty_string() | ne_binary()) -> 'ok' | {'error', any()}.
stop_app(App) when is_atom(App) ->
    case application:stop(App) of
        'ok' -> lager:info("stopped kazoo application ~s", [App]);
        {'error', {'not_started', App}} ->
            lager:error("~s is not currently running", [App]);
        {'error', _E}=Err ->
            lager:error("error stopping applicaiton ~s: ~p", [App, _E]),
            Err
    end;
stop_app(App) ->
    stop_app(kz_util:to_atom(App)).

-spec restart_app(atom() | nonempty_string() | ne_binary()) -> 'ok' | {'error', any()}.
restart_app(App) when is_atom(App) ->
    lager:info("restarting kazoo application ~s", [App]),
    _ = stop_app(App),
    start_app(App);
restart_app(App) ->
    restart_app(kz_util:to_atom(App, 'true')).

-spec running_apps() -> atoms() | string().
-spec running_apps(boolean()) -> atoms() | string().
running_apps() ->
    running_apps('false').

running_apps(Verbose) ->
    case kz_util:is_true(Verbose) of
        'true' -> running_apps_verbose();
        'false' -> running_apps_list()
    end.

-spec running_apps_verbose() -> atoms() | string().
running_apps_verbose() ->
    case get_running_apps() of
        [] -> "kapps have not started yet, check that rabbitmq and bigcouch/haproxy are running at the configured addresses";
        Resp ->
            lists:sort(
              [kz_util:to_binary(io_lib:format("~s(~s): ~s~n", [App, Vsn, Desc]))
               || {App, Desc, Vsn} <- Resp
              ]
             )
    end.

-spec get_running_apps() -> [{atom(), string(), _}].
get_running_apps() ->
    [AppData
     || {App, _Desc, _Vsn}=AppData <- application:which_applications(),
        not lists:member(App, ?HIDDEN_APPS)
    ].

-spec running_apps_list() -> atoms() | string().
running_apps_list() ->
    case get_running_apps() of
        [] -> "kapps have not started yet, check that rabbitmq and bigcouch/haproxy are running at the configured addresses";
        Resp -> lists:sort([App || {App, _Desc, _Vsn} <- Resp])
    end.

-spec initialize_kapps() -> 'ok'.
initialize_kapps() ->
    kz_util:put_callid(?LOG_SYSTEM_ID),
    kz_datamgr:db_exists(?KZ_ACCOUNTS_DB)
        orelse kapps_maintenance:refresh(),
    ToStart = [kz_util:to_atom(KApp, 'true') || KApp <- start_which_kapps()],
    Started = [KApp || KApp <- lists:sort(fun sysconf_first/2, ToStart),
                       {'ok',_} <- [start_app(KApp)]
              ],
    lager:notice("auto-started kapps ~p", [Started]).

-spec start_which_kapps() -> [ne_binary() | atom() | nonempty_string()].
start_which_kapps() ->
    Routines = [fun maybe_start_from_env/0
               ,fun maybe_start_from_node_config/0
               ,fun maybe_start_from_node_name/0
               ,fun start_from_default_config/0
               ],
    lists:foldl(fun(F, 'false') ->
                        F();
                   (_, Apps) ->
                        Apps
                end
               ,'false'
               ,Routines
               ).

-spec maybe_start_from_env() -> 'false' | [nonempty_string()].
maybe_start_from_env() ->
    case os:getenv("KAZOO_APPS", "noenv") of
        "noenv" -> 'false';
        KazooApps ->
            lager:info("starting applications specified in environment variable KAZOO_APPS: ~s"
                      ,[KazooApps]),
            string:tokens(KazooApps, ", ")
    end.

-spec maybe_start_from_node_name() -> 'false' | atoms().
maybe_start_from_node_name() ->
    KApp = kapp_from_node_name(),
    case not lists:member(KApp, ?HIDDEN_APPS)
        andalso code:where_is_file(kz_util:to_list(KApp) ++ ".app")
    of
        'false' -> 'false';
        'non_existing' -> 'false';
        _Else ->
            lager:info("starting application based on node name: ~s", [KApp]),
            [KApp]
    end.

-spec maybe_start_from_node_config() -> 'false' | [ne_binary() | atom()].
maybe_start_from_node_config() ->
    case kapps_config:get_node_value(?MODULE, <<"kapps">>) of
        'undefined' -> 'false';
        KazooApps ->
            lager:info("starting applications configured specifically for this node: ~s"
                      ,[kz_util:join_binary(KazooApps, <<", ">>)]),
            KazooApps
    end.

-spec start_from_default_config() -> 'false' | [ne_binary() | atom()].
start_from_default_config() ->
    lager:info("starting applications from default configuration"),
    kapps_config:get(?MODULE, <<"kapps">>, ?DEFAULT_KAPPS).

-spec kapp_from_node_name() -> atom().
kapp_from_node_name() ->
    kz_util:to_atom(hd(binary:split(kz_util:to_binary(node()), <<$@>>)), 'true').

-spec sysconf_first(atom(), atom()) -> boolean().
sysconf_first('sysconf', _) -> 'true';
sysconf_first(_, 'sysconf') -> 'false';
sysconf_first(_, _) -> 'true'.

-spec list_apps() -> atoms().
list_apps() ->
    case get_running_apps() of
        [] ->
            [kz_util:to_atom(KApp, 'true')
             || KApp <- start_which_kapps()
            ];
        Resp -> [App || {App, _, _} <- Resp]
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
