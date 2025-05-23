%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_retainer_schema).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-export([roots/0, fields/1, desc/1, namespace/0]).

-define(DEFAULT_INDICES, [
    [1, 2, 3],
    [1, 3],
    [2, 3],
    [3]
]).

-define(INVALID_SPEC(_REASON_), throw({_REASON_, #{default => ?DEFAULT_INDICES}})).

namespace() -> retainer.

roots() ->
    [
        {"retainer",
            hoconsc:mk(hoconsc:ref(?MODULE, "retainer"), #{
                converter => fun retainer_converter/2,
                validator => fun validate_backends_enabled/1
            })}
    ].

fields("retainer") ->
    [
        {enable,
            ?HOCON(
                boolean(),
                #{
                    desc => ?DESC(enable),
                    default => true,
                    deprecated => {since, "5.9.0"},
                    importance => ?IMPORTANCE_NO_DOC
                }
            )},
        {msg_expiry_interval,
            ?HOCON(
                %% not used in a `receive ... after' block, just timestamp comparison
                emqx_schema:duration_ms(),
                #{
                    desc => ?DESC(msg_expiry_interval),
                    default => <<"0s">>
                }
            )},
        {msg_expiry_interval_override,
            ?HOCON(
                %% not used in a `receive ... after' block, just timestamp comparison
                hoconsc:union([disabled, emqx_schema:duration_ms()]),
                #{
                    desc => ?DESC(msg_expiry_interval_override),
                    default => disabled
                }
            )},
        {allow_never_expire,
            ?HOCON(
                boolean(),
                #{
                    desc => ?DESC(allow_never_expire),
                    default => true
                }
            )},
        {msg_clear_interval,
            ?HOCON(
                emqx_schema:timeout_duration_ms(),
                #{
                    desc => ?DESC(msg_clear_interval),
                    default => <<"0s">>
                }
            )},
        {msg_clear_limit,
            ?HOCON(
                pos_integer(),
                #{
                    desc => ?DESC(msg_clear_limit),
                    default => 50_000,
                    importance => ?IMPORTANCE_HIDDEN
                }
            )},
        {flow_control,
            ?HOCON(
                ?R_REF(flow_control),
                #{
                    desc => ?DESC(flow_control),
                    default => #{},
                    importance => ?IMPORTANCE_HIDDEN
                }
            )},
        {max_payload_size,
            ?HOCON(
                emqx_schema:bytesize(),
                #{
                    desc => ?DESC(max_payload_size),
                    default => <<"1MB">>
                }
            )},
        {stop_publish_clear_msg,
            ?HOCON(
                boolean(),
                #{
                    desc => ?DESC(stop_publish_clear_msg),
                    default => false
                }
            )},
        {delivery_rate,
            ?HOCON(
                emqx_limiter_schema:rate_type(),
                #{
                    required => false,
                    desc => ?DESC(delivery_rate),
                    default => <<"1000/s">>,
                    example => <<"1000/s">>,
                    aliases => [deliver_rate]
                }
            )},
        {max_publish_rate,
            ?HOCON(
                emqx_limiter_schema:rate_type(),
                #{
                    required => false,
                    desc => ?DESC(max_publish_rate),
                    default => <<"1000/s">>,
                    example => <<"1000/s">>
                }
            )},
        {backend, backend_config()},
        {external_backends,
            ?HOCON(
                hoconsc:ref(?MODULE, external_backends),
                #{
                    desc => ?DESC(backends),
                    required => false,
                    default => #{},
                    importance => ?IMPORTANCE_HIDDEN
                }
            )}
    ];
fields(mnesia_config) ->
    [
        {type,
            ?HOCON(
                built_in_database,
                #{
                    desc => ?DESC(mnesia_config_type),
                    required => false,
                    default => built_in_database
                }
            )},
        {storage_type,
            ?HOCON(
                hoconsc:enum([ram, disc]),
                #{
                    desc => ?DESC(mnesia_config_storage_type),
                    default => ram
                }
            )},
        {max_retained_messages,
            ?HOCON(
                non_neg_integer(),
                #{
                    desc => ?DESC(max_retained_messages),
                    default => 0
                }
            )},
        {index_specs, fun retainer_indices/1},
        {enable,
            ?HOCON(
                boolean(), #{
                    desc => ?DESC(mnesia_enable),
                    importance => ?IMPORTANCE_NO_DOC,
                    required => false,
                    default => true
                }
            )}
    ];
fields(flow_control) ->
    [
        {batch_read_number,
            ?HOCON(
                non_neg_integer(),
                #{
                    desc => ?DESC(batch_read_number),
                    default => 0
                }
            )},
        {batch_deliver_number,
            ?HOCON(
                non_neg_integer(),
                #{
                    desc => ?DESC(batch_deliver_number),
                    default => 0
                }
            )},
        {batch_deliver_limiter,
            ?HOCON(
                emqx_limiter_schema:rate_type(),
                #{
                    desc => ?DESC(batch_deliver_limiter),
                    default => <<"1000/s">>
                }
            )}
    ];
fields(external_backends) ->
    emqx_schema_hooks:list_injection_point('retainer.external_backends').

desc("retainer") ->
    "Configuration related to handling `PUBLISH` packets with a `retain` flag set to 1.";
desc(mnesia_config) ->
    "Configuration of the internal database storing retained messages.";
desc(flow_control) ->
    "Retainer batching and rate limiting.";
desc(_) ->
    undefined.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

backend_config() ->
    hoconsc:mk(hoconsc:ref(?MODULE, mnesia_config), #{desc => ?DESC(backend)}).

retainer_indices(type) ->
    list(list(integer()));
retainer_indices(desc) ->
    "Retainer index specifications: list of arrays of positive ascending integers. "
    "Each array specifies an index. Numbers in an index specification are 1-based "
    "word positions in topics. Words from specified positions will be used for indexing.<br/>"
    "For example, it is good to have <code>[2, 4]</code> index to optimize "
    "<code>+/X/+/Y/...</code> topic wildcard subscriptions.";
retainer_indices(example) ->
    [[2, 4], [1, 3]];
retainer_indices(default) ->
    ?DEFAULT_INDICES;
retainer_indices(validator) ->
    fun check_index_specs/1;
retainer_indices(_) ->
    undefined.

check_index_specs([]) ->
    ok;
check_index_specs(IndexSpecs) when is_list(IndexSpecs) ->
    lists:foreach(fun check_index_spec/1, IndexSpecs),
    check_duplicate(IndexSpecs);
check_index_specs(_IndexSpecs) ->
    ?INVALID_SPEC(list_index_spec_limited).

check_index_spec([]) ->
    ?INVALID_SPEC(non_empty_index_spec_limited);
check_index_spec(IndexSpec) when is_list(IndexSpec) ->
    case lists:all(fun(Idx) -> is_integer(Idx) andalso Idx > 0 end, IndexSpec) of
        false -> ?INVALID_SPEC(pos_integer_index_limited);
        true -> check_duplicate(IndexSpec)
    end;
check_index_spec(_IndexSpec) ->
    ?INVALID_SPEC(list_index_spec_limited).

check_duplicate(List) ->
    case length(List) =:= length(lists:usort(List)) of
        false -> ?INVALID_SPEC(unique_index_spec_limited);
        true -> ok
    end.

retainer_converter(Conf0, _Opts) ->
    Conf1 = rename_delivery_rate(Conf0),
    convert_delivery_rate(Conf1).

rename_delivery_rate(#{<<"deliver_rate">> := Delivery} = Conf) ->
    Conf1 = maps:remove(<<"deliver_rate">>, Conf),
    Conf1#{<<"delivery_rate">> => Delivery};
rename_delivery_rate(Conf) ->
    Conf.

convert_delivery_rate(#{<<"delivery_rate">> := <<"infinity">>} = Conf) ->
    FlowControl0 = maps:get(<<"flow_control">>, Conf, #{}),
    FlowControl1 = FlowControl0#{
        <<"batch_read_number">> => 0,
        <<"batch_deliver_number">> => 0,
        <<"batch_deliver_limiter">> => <<"infinity">>
    },
    Conf#{<<"flow_control">> => FlowControl1};
convert_delivery_rate(#{<<"delivery_rate">> := RateStr} = Conf) ->
    {ok, {Capacity, _Interval}} = emqx_limiter_schema:to_rate(RateStr),
    FlowControl0 = maps:get(<<"flow_control">>, Conf, #{}),
    FlowControl1 = FlowControl0#{
        <<"batch_read_number">> => maps:get(<<"batch_read_number">>, FlowControl0, Capacity),
        <<"batch_deliver_number">> => maps:get(<<"batch_deliver_number">>, FlowControl0, Capacity),
        %% Set the maximum delivery rate per session
        <<"batch_deliver_limiter">> => RateStr
    },
    Conf#{<<"flow_control">> => FlowControl1};
convert_delivery_rate(Conf) ->
    Conf.

validate_backends_enabled(Config) ->
    BuiltInBackend = maps:get(<<"backend">>, Config, #{}),
    ExternalBackends = maps:values(maps:get(<<"external_backends">>, Config, #{})),
    Enabled = lists:filter(fun(#{<<"enable">> := E}) -> E end, [BuiltInBackend | ExternalBackends]),
    case Enabled of
        [#{}] ->
            ok;
        _Conflicts = [_ | _] ->
            {error, multiple_enabled_backends};
        _None = [] ->
            {error, no_enabled_backend}
    end.
