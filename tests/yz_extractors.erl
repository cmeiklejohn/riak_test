%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%-------------------------------------------------------------------

%% @doc Test that checks if we're caching the extractor map and that
%%      creating custom extractors is doable via protobufs.
%% @end

-module(yz_extractors).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").
-include_lib("riakc/include/riakc.hrl").

-define(INDEX1, <<"test_idx1">>).
-define(BUCKET1, <<"test_bkt1">>).
-define(INDEX2, <<"test_idx2">>).
-define(BUCKET2, <<"test_bkt2">>).
-define(YZ_CAP, {yokozuna, extractor_map_in_cmd}).
-define(GET_MAP_RING_MFA, {yz_extractor, get_map, 1}).
-define(GET_MAP_MFA, {yz_extractor, get_map, 0}).
-define(GET_MAP_READTHROUGH_MFA, {yz_extractor, get_map_read_through, 0}).
-define(YZ_META_EXTRACTORS, {yokozuna, extractors}).
-define(YZ_EXTRACTOR_MAP, yokozuna_extractor_map).
-define(NEW_EXTRACTOR, {"application/httpheader", yz_noop_extractor}).
-define(DEFAULT_MAP, [{default, yz_noop_extractor},
                      {"application/json",yz_json_extractor},
                      {"application/riak_counter", yz_dt_extractor},
                      {"application/riak_map", yz_dt_extractor},
                      {"application/riak_set", yz_dt_extractor},
                      {"application/xml",yz_xml_extractor},
                      {"text/plain",yz_text_extractor},
                      {"text/xml",yz_xml_extractor}
                     ]).
-define(EXTRACTMAPEXPECT, lists:sort(?DEFAULT_MAP ++ [?NEW_EXTRACTOR])).
-define(SEQMAX, 20).
-define(CFG,
        [
         {yokozuna,
          [
           {enabled, true}
          ]}
        ]).

confirm() ->
    %% This test explicitly requires an upgrade from 2.0.5 to test a
    %% new capability
    OldVsn = "2.0.5",

    [_, Node|_] = Cluster = rt:build_cluster(lists:duplicate(4, {OldVsn, ?CFG})),
    rt:wait_for_cluster_service(Cluster, yokozuna),

    [rt:assert_capability(ANode, ?YZ_CAP, {unknown_capability, ?YZ_CAP}) || ANode <- Cluster],

    OldPid = rt:pbc(Node),

    %% Generate keys, YZ only supports UTF-8 compatible keys
    GenKeys = [<<N:64/integer>> || N <- lists:seq(1, ?SEQMAX),
                                  not lists:any(
                                        fun(E) -> E > 127 end,
                                        binary_to_list(<<N:64/integer>>))],
    KeyCount = length(GenKeys),

    rt:count_calls(Cluster, [?GET_MAP_RING_MFA, ?GET_MAP_MFA]),

    yokozuna_rt:write_data(Cluster, OldPid, ?INDEX1, ?BUCKET1, GenKeys),

    ok = rt:stop_tracing(),

    %% wait for solr soft commit
    timer:sleep(1100),

    {ok, BProps} = riakc_pb_socket:get_bucket(OldPid, ?BUCKET1),
    N = proplists:get_value(n_val, BProps),

    riakc_pb_socket:stop(OldPid),

    PrevGetMapRingCC = rt:get_call_count(Cluster, ?GET_MAP_RING_MFA),
    PrevGetMapCC = rt:get_call_count(Cluster, ?GET_MAP_MFA),
    ?assertEqual(KeyCount * N, PrevGetMapRingCC),
    ?assertEqual(KeyCount * N, PrevGetMapCC),

    %% test query count
    yokozuna_rt:verify_num_found_query(Cluster, ?INDEX1, KeyCount),

    {RingVal1, MDVal1} = get_ring_and_cmd_vals(Node, ?YZ_META_EXTRACTORS,
                                               ?YZ_EXTRACTOR_MAP),

    ?assertEqual(undefined, MDVal1),
    %% In previous version, Ring only gets map metadata if a non-default
    %% extractor is registered
    ?assertEqual(undefined, RingVal1),

    ?assertEqual(?DEFAULT_MAP, get_map(Node)),

    %% Custom Register
    ExtractMap = register_extractor(Node, element(1, ?NEW_EXTRACTOR),
                                    element(2, ?NEW_EXTRACTOR)),

    ?assertEqual(?EXTRACTMAPEXPECT, ExtractMap),

    %% Upgrade
    yokozuna_rt:rolling_upgrade(Cluster, current),

    [rt:assert_capability(ANode, ?YZ_CAP, true) || ANode <- Cluster],
    [rt:assert_supported(rt:capability(ANode, all), ?YZ_CAP, [true, false]) || ANode <- Cluster],

    %% test query count again
    yokozuna_rt:verify_num_found_query(Cluster, ?INDEX1, KeyCount),

    Pid = rt:pbc(Node),

    rt:count_calls(Cluster, [?GET_MAP_RING_MFA, ?GET_MAP_MFA,
                             ?GET_MAP_READTHROUGH_MFA]),

    yokozuna_rt:write_data(Cluster, Pid, ?INDEX2, ?BUCKET2, GenKeys),
    riakc_pb_socket:stop(Pid),

    ok = rt:stop_tracing(),

    %% wait for solr soft commit
    timer:sleep(1100),

    CurrGetMapRingCC = rt:get_call_count(Cluster, ?GET_MAP_RING_MFA),
    CurrGetMapCC = rt:get_call_count(Cluster, ?GET_MAP_MFA),
    CurrGetMapRTCC = rt:get_call_count(Cluster, ?GET_MAP_READTHROUGH_MFA),

    lager:info("Number of calls to get the map from the ring - current: ~p~n, previous: ~p~n",
              [CurrGetMapRingCC, PrevGetMapRingCC]),
    ?assert(CurrGetMapRingCC < PrevGetMapRingCC),
    lager:info("Number of calls to get the map - current: ~p~n, previous: ~p~n",
               [CurrGetMapCC, PrevGetMapCC]),
    ?assert(CurrGetMapCC =< PrevGetMapCC),
    lager:info("Number of calls to get_map_read_through/0: ~p~n, Number of calls to get_map/0: ~p~n",
              [CurrGetMapRTCC, CurrGetMapCC]),
    ?assert(CurrGetMapRTCC < CurrGetMapCC),

    {_RingVal2, MDVal2} = get_ring_and_cmd_vals(Node, ?YZ_META_EXTRACTORS,
                                                ?YZ_EXTRACTOR_MAP),

    ?assertEqual(?EXTRACTMAPEXPECT, MDVal2),
    ?assertEqual(?EXTRACTMAPEXPECT, get_map(Node)),

    rt_intercept:add(Node, {yz_noop_extractor,
                            [{{extract, 1}, extract_httpheader}]}),
    rt_intercept:wait_until_loaded(Node),

    ExpectedExtraction = [{method,'GET'},
                          {host,<<"www.google.com">>},
                          {uri,<<"/">>}],
    ?assertEqual(ExpectedExtraction,
                 verify_extractor(Node,
                                  <<"GET http://www.google.com HTTP/1.1\n">>,
                                  element(2, ?NEW_EXTRACTOR))),

    pass.

%%%===================================================================
%%% Private
%%%===================================================================

get_ring_and_cmd_vals(Node, Prefix, Key) ->
    Ring = rpc:call(Node, yz_misc, get_ring, [transformed]),
    MDVal = metadata_get(Node, Prefix, Key),
    RingVal = ring_meta_get(Node, Key, Ring),
    {RingVal, MDVal}.

metadata_get(Node, Prefix, Key) ->
    rpc:call(Node, riak_core_metadata, get, [Prefix, Key, []]).

ring_meta_get(Node, Key, Ring) ->
    rpc:call(Node, riak_core_ring, get_meta, [Key, Ring]).

register_extractor(Node, MimeType, Mod) ->
    rpc:call(Node, yz_extractor, register, [MimeType, Mod]).

get_map(Node) ->
    rpc:call(Node, yz_extractor, get_map, []).

verify_extractor(Node, PacketData, Mod) ->
    rpc:call(Node, yz_extractor, run, [PacketData, Mod]).
