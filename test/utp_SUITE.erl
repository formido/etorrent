-module(utp_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([suite/0, all/0, groups/0,
	 init_per_group/2, end_per_group/2,
	 init_per_suite/1, end_per_suite/1,
	 init_per_testcase/2, end_per_testcase/2]).

-export([connect_n_communicate/0, connect_n_communicate/1,
         backwards_communication/0, backwards_communication/1,
         full_duplex_communication/0, full_duplex_communication/1,
         close_1/0, close_1/1,
         close_2/0, close_2/1,
         close_3/0, close_3/1,
         connect_n_send_big/0, connect_n_send_big/1 ]).

suite() ->
    [{timetrap, {seconds, 45}}].

%% Setup/Teardown
%% ----------------------------------------------------------------------
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_suite(Config) ->
    {ok, ConnectNode} = test_server:start_node('connector', slave, []),
    ok = rpc:call(ConnectNode, utp, start_app, [3334]),    
    {ok, ConnecteeNode} = test_server:start_node('connectee', slave, []),
    ok = rpc:call(ConnecteeNode, utp, start_app, [3333]),
    [{connector, ConnectNode},
     {connectee, ConnecteeNode} | Config].

end_per_suite(Config) ->
    test_server:stop_node(?config(connector, Config)),
    test_server:stop_node(?config(connectee, Config)),
    ok.

init_per_testcase(connect_n_communicate, Config) ->
    Config;
init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(_Case, _Config) ->
    ok.


%% Tests
%% ----------------------------------------------------------------------
groups() ->
    [{main_group, [shuffle], [connect_n_communicate,
                              backwards_communication,
                              full_duplex_communication,
                              close_1,
                              close_2,
                              close_3,
                              connect_n_send_big]}].

all() ->
    [{group, main_group}].

closer(Config, In, Out) ->
    C1 = ?config(connector, Config),
    C2 = ?config(connectee, Config),
    spawn(fun() ->
                  timer:sleep(3000),
                  ok = rpc:call(C1, utp, Out, [])
          end),
    ok = rpc:call(C2, utp, In, []),
    ok.

close_1() ->
    [].

close_1(Config) ->
    closer(Config, test_close_in_1, test_close_out_1).

close_2() ->    
    [].

close_2(Config) ->
    closer(Config, test_close_in_2, test_close_out_2).

close_3() ->
    [].

close_3(Config) ->
    closer(Config, test_close_in_3, test_close_out_3).

backwards_communication() ->
    [].

backwards_communication(Config) ->
    C1 = ?config(connector, Config),
    C2 = ?config(connectee, Config),
    spawn(fun() ->
                  timer:sleep(3000),
                  ok = rpc:call(C1, utp, test_connector_2, [])
          end),
    ok = rpc:call(C2, utp, test_connectee_2, []),
    ok.

full_duplex_communication() ->
    [].

full_duplex_communication(Config) ->
    C1 = ?config(connector, Config),
    C2 = ?config(connectee, Config),
    spawn(fun() ->
                  timer:sleep(3000),
                  ok = rpc:call(C1, utp, test_connector_3, [])
          end),
    ok = rpc:call(C2, utp, test_connectee_3, []),
    ok.
    
connect_n_communicate() ->
    [].

connect_n_communicate(Config) ->
    C1 = ?config(connector, Config),
    C2 = ?config(connectee, Config),
    spawn(fun() ->
                  %% @todo, should fix this timer invocation
                  timer:sleep(3000),
                  rpc:call(C1, utp, test_connector_1, [])
          end),
    {<<"HELLO">>, <<"WORLD">>} = rpc:call(C2, utp, test_connectee_1, []),
    ok.

connect_n_send_big() ->
    [{timetrap, {seconds, 120}}].

connect_n_send_big(Config) ->
    DataDir = ?config(data_dir, Config),
    {ok, FileData} = file:read_file(filename:join([DataDir, "test_large_send.dat"])),
    spawn(fun() ->
                  timer:sleep(3000),
                  rpc:call(?config(connector, Config),
                           utp, test_send_large_file, [FileData])
          end),
    ReadData = rpc:call(?config(connectee, Config),
                        utp, test_recv_large_file, [byte_size(FileData)]),
    FileData = ReadData.

%% Helpers
%% ----------------------------------------------------------------------
