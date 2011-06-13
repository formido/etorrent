-module(utp_ledbat).

-define(BASE_DELAY_HISTORY_SIZE, 13).
-define(CUR_DELAY_SIZE, 3).

-export([
         mk/1,
         add_sample/2,
         shift/2,
         get_value/1,
         clock_tick/1
        ]).

-record(ledbat, { base_history_q :: queue(),
                  delay_base :: integer(),
                  delay_history_q   :: queue() }).

-opaque t() :: #ledbat{}.

-export_type([
              t/0
             ]).

mk(Sample) ->
    BaseQueue = lists:foldr(fun(_E, Q) -> queue:in(Sample, Q) end,
                            queue:new(),
                            lists:seq(1, ?BASE_DELAY_HISTORY_SIZE)),
    DelayQueue = lists:foldr(fun(_E, Q) -> queue:in(0, Q) end,
                             queue:new(),
                             lists:seq(1, ?CUR_DELAY_SIZE)),
    #ledbat { base_history_q = BaseQueue,
              delay_base     = Sample,
              delay_history_q = DelayQueue}.

shift(#ledbat { base_history_q = BQ } = LEDBAT, Offset) ->
    New_Queue = queue_map(fun(E) ->
                                  bit32(E + Offset)
                          end,
                          BQ),
    LEDBAT#ledbat { base_history_q = New_Queue }.

add_sample(#ledbat { base_history_q = BQ,
                     delay_base     = DelayBase,
                     delay_history_q   = DQ } = LEDBAT, Sample) ->
    {value, BaseIncumbent, BQ2} = queue:out(BQ),
    {value, _DelayIncumbent, DQ2} = queue:out(DQ),
    N_BQ = case compare_less(Sample, BaseIncumbent) of
               true ->
                   queue:in_r(Sample, BQ2);
               false ->
                   BQ
           end,
    N_DelayBase = case compare_less(Sample, DelayBase) of
                      true -> Sample;
                      false -> DelayBase
                  end,
    Delay = bit32(Sample - N_DelayBase),
    N_DQ = queue:in(Delay, DQ2),
    LEDBAT#ledbat { base_history_q = N_BQ,
                    delay_base = Delay,
                    delay_history_q = N_DQ }.


clock_tick(#ledbat{ delay_history_q = DelayQ,
                    base_history_q  = BaseQ } = LEDBAT) ->
    N_DelayBase = minimum_by(fun compare_less/2, queue:to_list(BaseQ)),
    LEDBAT#ledbat { delay_history_q = rotate(DelayQ),
                    delay_base = N_DelayBase }.


get_value(#ledbat { delay_history_q = DelayQ }) ->
    lists:min(queue:to_list(DelayQ)).

%% ----------------------------------------------------------------------
minimum_by(_F, []) ->
    error(badarg);
minimum_by(F, [H | T]) ->
    minimum_by(F, T, H).

minimum_by(_Comparator, [], M) ->
    M;
minimum_by(Comparator, [H | T], M) ->
    case Comparator(H, M) of
        true ->
            minimum_by(Comparator, T, H);
        false ->
            minimum_by(Comparator, T, M)
    end.

rotate(Q) ->
    {value, E, RQ} = queue:out(Q),
    queue:in(E, RQ).

bit32(X) ->
    X band 16#FFFFFFFF.

%% @doc Compare if L < R taking wrapping into account
compare_less(L, R) ->
    %% To see why this is correct, imagine a unit circle
    %% One direction is walking downwards from the L clockwise until
    %%  we hit the R
    %% The other direction is walking upwards, counter-clockwise
    Down = bit32(L - R),
    Up   = bit32(R - L),

    %% If the walk-up distance is the shortest, L < R, otherwise R < L
    Up < Down.

queue_map(F, Q) ->
    L = queue:to_list(Q),
    queue:from_list(lists:map(F, L)).


