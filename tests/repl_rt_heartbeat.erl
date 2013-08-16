%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.
%%
%% -------------------------------------------------------------------
-module(repl_rt_heartbeat).
-behaviour(riak_test).
-export([confirm/0]).
-include_lib("eunit/include/eunit.hrl").

-define(RPC_TIMEOUT, 5000).
-define(HB_TIMEOUT,  4000).

%% Replication Realtime Heartbeat test
%% Valid for EE version 1.3.2 and up
%%
%% If both sides of an RT replication connection support it, a heartbeat
%% message is sent from the RT Source to the RT Sink every
%% {riak_repl, rt_heartbeat_interval} which default to 15s.  If
%% a response is not received in {riak_repl, rt_heartbeat_timeout}, also
%% default to 15s then the source connection exits and will be re-established
%% by the supervisor.
%%
%% RT Heartbeat messages are supported between EE releases 1.3.2 and up.
%%
%% Test:
%% -----
%% Change the heartbeat_interval and heartbeat_timeout to 2 seconds,
%% Start up two >1.3.2 clusters and connect them,
%% Enable RT replication,
%% Write some objects to the source cluster (A),
%% Verify they got to the sink cluster (B),
%% Verify that heartbeats are being acknowledged by the sink (B) back to source (A),
%% Interupt the connection so that packets can not flow from A -> B,
%% Verify that the connection is restarted after the heartbeat_timeout period,
%% Verify that heartbeats are being acknowledged by the sink (B) back to source (A),
%% Write some objects to the source cluster (A),
%% Verify they got to the sink cluster (B),
%% Have a cold beverage.
%%
%% NOTE: Test was updated to send heartbeats 4 times faster than the timtout. But
%%       since we don't actually send them out the door, we'll have the hb_sent_q
%%       will have multiple HB's in it when we finally do get a HB back.

%% @doc riak_test entry point
confirm() ->
    %% Start up two >1.3.2 clusters and connect them,
    {LeaderA, LeaderB, ANodes, BNodes} = make_connected_clusters(),
    AllNodes = ANodes ++ BNodes,

    rpc:multicall(AllNodes, lager, trace_file, ["./log/console.log", [{module, riak_repl2_rtsource_conn}], debug]),

    %% load intercepts. See ../intercepts/riak_repl_rt_intercepts.erl
    load_intercepts(LeaderA), %% for the source
    load_intercepts(LeaderB), %% for the sink
    
    %% Enable RT replication from cluster "A" to cluster "B"
    enable_rt(LeaderA, ANodes),
    timer:sleep(?HB_TIMEOUT + 2000),

    %% Verify that heartbeats are being acknowledged by the sink (B) back to source (A)
    ?assertEqual(verify_heartbeat_messages(LeaderA), true),

    %% Verify RT repl of objects
    verify_rt(LeaderA, LeaderB),
    timer:sleep(?HB_TIMEOUT + 2000),

    %% Cause heartbeat messages to not be delivered, but remember the current
    %% Pid of the RT connection. It should change after we stop heartbeats
    %% because the RT connection will restart if all goes well.
    RTConnPid1 = get_rt_conn_pid(LeaderA),
    lager:info("Suspending HB"),
    suspend_heartbeat_messages(LeaderA),

    %% sleep longer than the HB timeout interval to force re-connection;
    %% and give it time to restart the RT connection. Wait an extra 2 seconds.
    timer:sleep(?HB_TIMEOUT + 2000),

    %% Verify that RT connection has restarted by noting that it's Pid has changed
    RTConnPid2 = get_rt_conn_pid(LeaderA),
    ?assertNotEqual(RTConnPid1, RTConnPid2),
    timer:sleep(?HB_TIMEOUT + 2000),

    %% Verify that heart beats are not being ack'd
    ?assertEqual(verify_heartbeat_messages(LeaderA), false),

    %% Resume heartbeat messages from source and allow some time to ack back.
    %% Wait one second longer than the timeout
    resume_heartbeat_messages(LeaderA),
    timer:sleep(?HB_TIMEOUT + 1000),

    %% Verify that heartbeats are being acknowledged by the sink (B) back to source (A)
    ?assertEqual(verify_heartbeat_messages(LeaderA), true),

    %% Verify RT repl of objects
    verify_rt(LeaderA, LeaderB),

    %% HB Queue Test...

    %% A plausible scenario that needs testing...
    %% Our config is such that the HB timeout >> HB interval
    %% We = RT Source Conn process
    %% We send one HB when we first connect to the sink (that's one item on the hb_send_q)
    %% We send some data to the sink.
    %% We receive an ack from our data, we don't remove an item from our hb_send_q, and we schedule another HB
    %% Our mailbox gets jammed with messages (from what?) that take longer than HB interval to process
    %% Thus, we don't recv a heartbeat echo from the sink (and thus don't dequeue an item from hb_send_q)
    %% We send the HB that we scheduled from the ack (that's two on the hb_send_q)

    %% SO, to test...
    %% slow the responses from the sink
    %% kill the RT connection so it will restart
    %% 

    rt:log_to_nodes(AllNodes, "Starting HB Sent Q phase"),
    rt:log_to_nodes(AllNodes, "Slowing HB responses"),
    [slow_heartbeat_responses(Node) || Node <- BNodes],
    %% Kill the RT connection to restart it
    RTConnPid3 = get_rt_conn_pid(LeaderA),
    exit(RTConnPid3, kill),
    timer:sleep(1000),
    RTConnPid4 = get_rt_conn_pid(LeaderA),
    %% send some data
    verify_rt(LeaderA, LeaderB),
    rt:log_to_nodes(AllNodes, "Resuming normal HB responses"),
    [resume_heartbeat_responses(Node) || Node <- BNodes],
    %% Verify that heartbeats are being acknowledged by the sink (B) back to source (A)
    ?assertEqual(verify_heartbeat_messages(LeaderA), true),
    %% Verify that the connection didn't get killed since we tries this last test
    RTConnPid5 = get_rt_conn_pid(LeaderA),
    ?assertEqual(RTConnPid4, RTConnPid5),

    pass.

%% @doc Turn on Realtime replication on the cluster lead by LeaderA.
%%      The clusters must already have been named and connected.
enable_rt(LeaderA, ANodes) ->
    repl_util:enable_realtime(LeaderA, "B"),
    rt:wait_until_ring_converged(ANodes),

    repl_util:start_realtime(LeaderA, "B"),
    rt:wait_until_ring_converged(ANodes).

%% @doc Verify that RealTime replication is functioning correctly by
%%      writing some objects to cluster A and checking they can be
%%      read from cluster B. Each call creates a new bucket so that
%%      verification can be tested multiple times independently.
verify_rt(LeaderA, LeaderB) ->
    TestHash =  list_to_binary([io_lib:format("~2.16.0b", [X]) ||
                <<X>> <= erlang:md5(term_to_binary(os:timestamp()))]),
    TestBucket = <<TestHash/binary, "-rt_test_a">>,
    First = 101,
    Last = 200,

    %% Write some objects to the source cluster (A),
    lager:info("Writing ~p keys to ~p, which should RT repl to ~p",
               [Last-First+1, LeaderA, LeaderB]),
    ?assertEqual([], repl_util:do_write(LeaderA, First, Last, TestBucket, 2)),

    %% verify data is replicated to B
    lager:info("Reading ~p keys written from ~p", [Last-First+1, LeaderB]),
    ?assertEqual(0, repl_util:wait_for_reads(LeaderB, First, Last, TestBucket, 2)).

%% @doc Connect two clusters for replication using their respective leader nodes.
connect_clusters(LeaderA, LeaderB) ->
    {ok, {_IP, Port}} = rpc:call(LeaderB, application, get_env,
                                 [riak_core, cluster_mgr]),
    lager:info("connect cluster A:~p to B on port ~p", [LeaderA, Port]),
    repl_util:connect_cluster(LeaderA, "127.0.0.1", Port),
    ?assertEqual(ok, repl_util:wait_for_connection(LeaderA, "B")).

%% @doc Create two clusters of 3 nodes each and connect them for replication:
%%      Cluster "A" -> cluster "B"
make_connected_clusters() ->
    %% For riak_test version 1.3, we can't use rt_config:get
    NumNodes = 6,
    ClusterASize = 3,

    lager:info("Deploy ~p nodes", [NumNodes]),
    Conf = [
            {riak_repl,
             [
              %% turn off fullsync
              {fullsync_on_connect, false},
              {fullsync_interval, disabled},
              %% override defaults for RT heartbeat so that we
              %% can see faults sooner and have a quicker test.
              %% Send HB's at 8 times the rate of timeout so that
              %% we can put lots of them in the sent queue. See
              %% riak_repl2_rtsource_conn#state.hb_sent_q
              {rt_heartbeat_interval, (?HB_TIMEOUT div 8)},
              {rt_heartbeat_timeout, ?HB_TIMEOUT}
             ]}
    ],

    Nodes = rt:deploy_nodes(NumNodes, Conf),

    {ANodes, BNodes} = lists:split(ClusterASize, Nodes),
    lager:info("ANodes: ~p", [ANodes]),
    lager:info("BNodes: ~p", [BNodes]),

    lager:info("Build cluster A"),
    repl_util:make_cluster(ANodes),

    lager:info("Build cluster B"),
    repl_util:make_cluster(BNodes),

    %% get the leader for the first cluster
    lager:info("waiting for leader to converge on cluster A"),
    ?assertEqual(ok, repl_util:wait_until_leader_converge(ANodes)),
    AFirst = hd(ANodes),

    %% get the leader for the second cluster
    lager:info("waiting for leader to converge on cluster B"),
    ?assertEqual(ok, repl_util:wait_until_leader_converge(BNodes)),
    BFirst = hd(BNodes),

    %% Name the clusters
    repl_util:name_cluster(AFirst, "A"),
    rt:wait_until_ring_converged(ANodes),

    repl_util:name_cluster(BFirst, "B"),
    rt:wait_until_ring_converged(BNodes),

    %% Connect for replication
    connect_clusters(AFirst, BFirst),

    {AFirst, BFirst, ANodes, BNodes}.

%% @doc Load intercepts file from ../intercepts/riak_repl2_rtsource_helper_intercepts.erl
load_intercepts(Node) ->
    rt_intercept:load_code(Node).

%% @doc Suspend heartbeats from the source node
suspend_heartbeat_messages(Node) ->
    %% disable forwarding of the heartbeat function call
    lager:info("Suspend sending of heartbeats from source node ~p", [Node]),
    rt_intercept:add(Node, {riak_repl2_rtsource_helper,
                            [{{send_heartbeat, 1}, drop_send_heartbeat}]}).

%% @doc Resume heartbeats from the source node
resume_heartbeat_messages(Node) ->
    %% enable forwarding of the heartbeat function call
    lager:info("Resume sending of heartbeats from source node ~p", [Node]),
    rt_intercept:add(Node, {riak_repl2_rtsource_helper,
                            [{{send_heartbeat, 1}, forward_send_heartbeat}]}).

%% @doc Slow down HB's from the sink
slow_heartbeat_responses(Node) ->
    %% slow down the reply of the heartbeat from the sink
    lager:info("Slowing heartbeat acks from sink node ~p", [Node]),
    rt_intercept:add(Node, {riak_repl2_rtsink_conn,
                            [{{send_heartbeat, 2}, slow_send_heartbeat}]}).

%% @doc Resume normal HB's from the sink
resume_heartbeat_responses(Node) ->
    %% resume normal response time of heartbeats from the sink
    lager:info("Resume normal heartbeats from sink node ~p", [Node]),
    rt_intercept:add(Node, {riak_repl2_rtsink_conn,
                            [{{send_heartbeat, 2}, normal_send_heartbeat}]}).

%% @doc Get the Pid of the first RT source connection on Node
get_rt_conn_pid(Node) ->
    [{_Remote, Pid}|Rest] = rpc:call(Node, riak_repl2_rtsource_conn_sup, enabled, []),
    case Rest of
        [] -> ok;
        RR -> lager:info("Other connections: ~p", [RR])
    end,
    Pid.

%% @doc Verify that heartbeat messages are being ack'd from the RT sink back to source Node
verify_heartbeat_messages(Node) ->
    lager:info("Verify heartbeats"),
    Pid = get_rt_conn_pid(Node),
    Status = rpc:call(Node, riak_repl2_rtsource_conn, status, [Pid], ?RPC_TIMEOUT),
    HBRTT = proplists:get_value(hb_rtt, Status),
    case HBRTT of
        undefined ->
            false;
        RTT ->
            is_integer(RTT)
    end.
