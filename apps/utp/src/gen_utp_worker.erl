%%%-------------------------------------------------------------------
%%% @author Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%% @copyright (C) 2011, Jesper Louis andersen
%%% @doc
%%%
%%% @end
%%% Created : 19 Feb 2011 by Jesper Louis andersen <jesper.louis.andersen@gmail.com>
%%%-------------------------------------------------------------------
-module(gen_utp_worker).

-include("log.hrl").
-include("utp.hrl").

-behaviour(gen_fsm).

%% API
-export([start_link/4]).

%% Operations
-export([connect/1,
	 accept/2,
	 close/1,

	 recv/2,
	 send/2
	]).

%% Internal API
-export([
	 incoming/3,
	 reply/2
	]).

%% gen_fsm callbacks
-export([init/1, handle_event/3,
	 handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

%% gen_fsm callback states
-export([idle/2, idle/3,
	 syn_sent/2,
	 connected/2, connected/3,
	 got_fin/2, got_fin/3,
	 destroy_delay/2,
	 fin_sent/2, fin_sent/3,
	 reset/2, reset/3,
	 destroy/2]).

-type conn_state() :: idle | syn_sent | connected | got_fin
                    | destroy_delay | fin_sent | reset | destroy.

-type error_type() :: econnreset | econnrefused | etiemedout | emsgsize.
-type ret_value()  :: ok | {ok, binary()} | {error, error_type()}.

-export_type([conn_state/0,
              error_type/0,
              ret_value/0]).

-define(SERVER, ?MODULE).
%% Default extensions to use when SYN/SYNACK'ing
-define(SYN_EXTS, [{ext_bits, <<0:64/integer>>}]).

%% Default SYN packet timeout
-define(SYN_TIMEOUT, 3000).
-define(DEFAULT_RETRANSMIT_TIMEOUT, 3000).
-define(SYN_TIMEOUT_THRESHOLD, ?SYN_TIMEOUT*2).
-define(RTT_VAR, 800). % Round trip time variance
-define(PACKET_SIZE, 350). % @todo Probably dead!
-define(MAX_WINDOW_USER, 255 * ?PACKET_SIZE). % Likewise!
-define(DEFAULT_ACK_TIME, 16#70000000). % Default add to the future when an Ack is expected
-define(DELAYED_ACK_BYTE_THRESHOLD, 2400). % bytes
-define(DELAYED_ACK_TIME_THRESHOLD, 100).  % milliseconds
-define(KEEPALIVE_INTERVAL, 29000). % ms

%% Number of bytes to increase max window size by, per RTT. This is
%% scaled down linearly proportional to off_target. i.e. if all packets
%% in one window have 0 delay, window size will increase by this number.
%% Typically it's less. TCP increases one MSS per RTT, which is 1500
-define(MAX_CWND_INCREASE_BYTES_PER_RTT, 3000).
-define(CUR_DELAY_SIZE, 3).

%% Default timeout value for sockets where we will destroy them!
-define(RTO_DESTROY_VALUE, 30*1000).

%% The delay to set on Zero Windows. It is awfully high, but that is what it has
%% to be it seems.
-define(ZERO_WINDOW_DELAY, 15*1000).

%% Experiments suggest that a clock skew of 10 ms per 325 seconds
%% is not impossible. Reset delay_base every 13 minutes. The clock
%% skew is dealt with by observing the delay base in the other
%% direction, and adjusting our own upwards if the opposite direction
%% delay base keeps going down
-define(DELAY_BASE_HISTORY, 13).
-define(MAX_WINDOW_DECAY, 100). % ms

-define(DEFAULT_OPT_RECV_SZ, 8192). %% @todo Fix this
-define(DEFAULT_PACKET_SIZE, 350). %% @todo Fix, arbitrary at the moment

-define(DEFAULT_FSM_TIMEOUT, 10*60*1000).
%% STATE RECORDS
%% ----------------------------------------------------------------------
-record(state, { sock_info    :: utp_socket:t(),
                 pkt_window   :: utp_window:t(),
                 pkt_buf      :: utp_pkt:buf(),
                 proc_info    :: utp_process:t(),
                 connector    :: {{reference(), pid()}, [{pkt, #packet{}, term()}]},
                 zerowindow_timeout :: undefined | {set, reference()},
                 retransmit_timeout :: undefined | {set, reference()},

                 options = [] :: [{atom(), term()}]
               }).

%%%===================================================================

%% @doc Create a worker for a peer endpoint
%% @end
start_link(Socket, Addr, Port, Options) ->
    gen_fsm:start_link(?MODULE, [Socket, Addr, Port, Options], []).

%% @doc Send a connect event
%% @end
connect(Pid) ->
    sync_send_event(Pid, connect).

%% @doc Send an accept event
%% @end
accept(Pid, SynPacket) ->
    sync_send_event(Pid, {accept, SynPacket}).

%% @doc Receive some bytes from the socket. Blocks until the said amount of
%% bytes have been read.
%% @end
recv(Pid, Amount) ->
    gen_fsm:sync_send_event(Pid, {recv, Amount}, infinity).

%% @doc Send some bytes from the socket. Blocks until the said amount of
%% bytes have been sent and has been accepted by the underlying layer.
%% @end
send(Pid, Data) ->
    gen_fsm:sync_send_event(Pid, {send, Data}, infinity).

%% @doc Send a close event
%% @end
close(Pid) ->
    %% Consider making it sync, but the de-facto implementation isn't
    gen_fsm:send_event(Pid, close).

%% ----------------------------------------------------------------------
incoming(Pid, Packet, Timing) ->
    gen_fsm:send_event(Pid, {pkt, Packet, Timing}).

reply(To, Msg) ->
    gen_fsm:reply(To, Msg).

sync_send_event(Pid, Event) ->
    gen_fsm:sync_send_event(Pid, Event, ?DEFAULT_FSM_TIMEOUT).


%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%% @private
init([Socket, Addr, Port, Options]) ->
    case validate_options(Options) of
        ok ->
            PktWindow  = utp_window:mk(),
            PktBuf   = utp_pkt:mk(?DEFAULT_OPT_RECV_SZ),
            ProcInfo = utp_process:mk(),
            CanonAddr = canonicalize_address(Addr),
            SockInfo = utp_socket:mk(CanonAddr, Options, ?DEFAULT_PACKET_SIZE, Port, Socket),
            {ok, idle, #state{ sock_info = SockInfo,
                               pkt_buf   = PktBuf,
                               proc_info = ProcInfo,
                               options=  Options,
                               pkt_window  = PktWindow }};
        badarg ->
            {stop, badarg}
    end.

%% @private
idle(close, S) ->
    {next_state, destroy, S, 0};
idle(_Msg, S) ->
    %% Ignore messages
    ?ERR([node(), async_message, idle, _Msg]),
    {next_state, idle, S}.

%% @private
syn_sent({pkt, #packet { ty = st_reset }, _},
         #state { proc_info = PRI,
                  connector = {From, _} } = State) ->
    %% We received a reset packet in the connected state. This means an abrupt
    %% disconnect, so move to the RESET state right away after telling people
    %% we can't fulfill their requests.
    N_PRI = error_all(PRI, econnrefused),
    %% Also handle the guy making the connection
    reply(From, econnrefused),
    {next_state, destroy, State#state { proc_info = N_PRI }, 0};
syn_sent({pkt, #packet { ty = st_state,
                         win_sz = WindowSize,
			 seq_no = PktSeqNo },
	       _Timing},
	 #state { sock_info = SockInfo,
                  pkt_buf = PktBuf,
                  pkt_window = PktWin,
                  connector = {From, Packets},
                  retransmit_timeout = RTimeout
                } = State) ->
    reply(From, ok),
    %% Empty the queue of packets for the new state
    %% We reverse the list so they are in the order we got them originally
    [incoming(self(), P, T) || {pkt, P, T} <- lists:reverse(Packets)],
    {next_state, connected,
     State#state { sock_info = SockInfo,
                   pkt_window = utp_window:handle_advertised_window(WindowSize,
                                                                    PktWin),
                   retransmit_timeout = clear_retransmit_timer(RTimeout),
                   pkt_buf = utp_pkt:init_ackno(PktBuf, utp_pkt:bit16(PktSeqNo+1))}};
syn_sent({pkt, _Packet, _Timing} = Pkt,
         #state { connector = {From, Packets}} = State) ->
    {next_state, syn_sent,
     State#state {
       connector = {From, [Pkt | Packets]}}};
syn_sent(close, #state {
           pkt_window = Window,
           retransmit_timeout = RTimeout
          } = State) ->
    clear_retransmit_timer(RTimeout),
    Gracetime = lists:min([60, utp_window:rto(Window) * 2]),
    Timer = set_retransmit_timer(Gracetime, undefined),
    {next_state, syn_sent, State#state {
                             retransmit_timeout = Timer }};
syn_sent({timeout, TRef, {retransmit_timeout, N}},
         #state { retransmit_timeout = {set, TRef},
                  sock_info = SockInfo,
                  connector = {From, _},
                  pkt_buf = PktBuf
                } = State) ->
    ?DEBUG([syn_timeout_triggered]),
    case N > ?SYN_TIMEOUT_THRESHOLD of
        true ->
            reply(From, {error, etimedout}),
            {next_state, reset, State#state {retransmit_timeout = undefined}};
        false ->
            % Resend packet
            SynPacket = mk_syn(),
            Win = utp_pkt:advertised_window(PktBuf),
            ok = utp_socket:send_pkt(Win, SockInfo, SynPacket,
                                     utp_socket:conn_id_recv(SockInfo)),
            ?DEBUG([syn_packet_resent]),
            {next_state, syn_sent,
             State#state {
               retransmit_timeout = set_retransmit_timer(N*2, undefined)
              }}
    end;
syn_sent(_Msg, S) ->
    %% Ignore messages
    ?ERR([node(), async_message, syn_sent, _Msg]),
    {next_state, syn_sent, S}.


%% @private
connected({pkt, #packet { ty = st_reset }, _},
          #state { proc_info = PRI } = State) ->
    %% We received a reset packet in the connected state. This means an abrupt
    %% disconnect, so move to the RESET state right away after telling people
    %% we can't fulfill their requests.
    N_PRI = error_all(PRI, econnreset),
    {next_state, reset, State#state { proc_info = N_PRI }};
connected({pkt, #packet { ty = st_syn }, _}, State) ->
    ?INFO([duplicate_syn_packet, ignoring]),
    {next_state, connected, State};
connected({pkt, Pkt, {_TS, _TSDiff, RecvTime}},
	  #state { retransmit_timeout = RetransTimer } = State) ->
    ?DEBUG([node(), incoming_pkt, connected, utp_proto:format_pkt(Pkt)]),

    {ok, Messages, N_PKI, N_PB, N_PRI, ZWinTimeout} =
        handle_packet_incoming(Pkt, RecvTime, State),
    N_RetransTimer = handle_retransmit_timer(Messages, RetransTimer),

    %% Calculate the next state
    NextState = case proplists:get_value(got_fin, Messages) of
                    true ->
                        got_fin;
                    undefined ->
                        connected
                end,
    {next_state, ?TRACE(NextState),
     State#state { pkt_window = N_PKI,
                   pkt_buf = N_PB,
                   retransmit_timeout = N_RetransTimer,
                   zerowindow_timeout = ZWinTimeout,
                   proc_info = N_PRI }};
connected(close, #state { sock_info = SockInfo,
                          retransmit_timeout = RTimer,
                          pkt_buf = PktBuf } = State) ->
    NPBuf = utp_pkt:send_fin(SockInfo, PktBuf),
    NRTimer = handle_retransmit_timer([fin_sent], RTimer),
    {next_state, fin_sent, State#state {
                             retransmit_timeout = NRTimer,
                             pkt_buf = NPBuf } };
connected({timeout, Ref, {zerowindow_timeout, _N}},
          #state {
            pkt_buf = PktBuf,
            proc_info = ProcessInfo,
            sock_info = SockInfo,
            pkt_window = WindowInfo,
            zerowindow_timeout = {set, Ref}} = State) ->
    N_Win = utp_window:bump_window(WindowInfo),
    {_FillMessages, ZWinTimer, N_PktBuf, N_ProcessInfo} =
        fill_window(SockInfo, ProcessInfo, N_Win, PktBuf, undefined),
    {next_state, connected,
     State#state {
       zerowindow_timeout = ZWinTimer,
       pkt_buf = N_PktBuf,
       pkt_window = N_Win,
       proc_info = N_ProcessInfo}};
connected({timeout, Ref, {retransmit_timeout, N}},
         #state { 
            pkt_buf = PacketBuf,
            sock_info = SockInfo,
            retransmit_timeout = {set, Ref} = Timer} = State) ->
    case handle_timeout(Ref, N, PacketBuf, SockInfo, Timer) of
        stray ->
            {next_state, connected, State};
        gave_up ->
            {next_state, reset, State};
        {reinstalled, N_Timer, N_PB} ->
            {next_state, connected, State#state { retransmit_timeout = N_Timer,
                                                  pkt_buf = N_PB }}
    end;
connected(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, connected, _Msg]),
    {next_state, connected, State}.

%% @private
got_fin(close, State) ->
    {next_state, destroy_delay, State};
got_fin({timeout, Ref, {retransmit_timeout, N}},
        #state { 
          pkt_buf = PacketBuf,
          sock_info = SockInfo,
          retransmit_timeout = Timer} = State) ->
    case handle_timeout(Ref, N, PacketBuf, SockInfo, Timer) of
        stray ->
            {next_state, got_fin, State};
        gave_up ->
            {next_state, reset, State};
        {reinstalled, N_Timer, N_PB} ->
            {next_state, got_fin, State#state { retransmit_timeout = N_Timer,
                                                pkt_buf = N_PB }}
    end;
got_fin({pkt, #packet { ty = st_state }, _}, State) ->
    %% State packets incoming can be ignored. Why? Because state packets from the other
    %% end doesn't matter at this point: We got the FIN completed, so we can't send or receive
    %% anymore. And all who were waiting are expunged from the receive buffer. No new can enter.
    %% Our Timeout will move us on (or a close). The other end is in the FIN_SENT state, so
    %% he will only send state packets when he needs to ack some of our stuff, which he wont.
    {next_state, got_fin, State};
got_fin({pkt, #packet { ty = st_fin }, _}, State) ->
    %% @todo We should probably send out an ACK for the FIN here since it is a retransmit
    {next_state, got_fin, State};
got_fin(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, got_fin, _Msg]),
    {next_state, got_fin, State}.

%% @private
destroy_delay({timeout, Ref, {retransmit_timeout, N}},
         #state { 
            pkt_buf = PacketBuf,
            sock_info = SockInfo,
            retransmit_timeout = Timer} = State) ->
    case handle_timeout(Ref, N, PacketBuf, SockInfo, Timer) of
        stray ->
            {next_state, destroy_delay, State};
        gave_up ->
            {next_state, destroy, State, 0};
        {reinstalled, N_Timer, N_PB} ->
            {next_state, destroy, State#state {
                                    retransmit_timeout = N_Timer,
                                    pkt_buf = N_PB}, 0}
    end;
destroy_delay({pkt, #packet { ty = st_fin }, _}, State) ->
    {next_state, destroy_delay, State};
destroy_delay(close, State) ->
    {next_state, destroy, State, 0};
destroy_delay(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, destroy_delay, _Msg]),
    {next_state, destroy_delay, State}.

%% @private
%% Die deliberately on close for now
fin_sent({pkt, #packet { ty = st_syn }, _},
         State) ->
    %% Quaff SYN packets if they arrive in this state. They are stray.
    %% I have seen it happen in tests, however unlikely that it happens in real life.
    {next_state, fin_sent, State};
fin_sent({pkt, #packet { ty = st_reset }, _},
         #state { proc_info = PRI } = State) ->
    %% We received a reset packet in the connected state. This means an abrupt
    %% disconnect, so move to the RESET state right away after telling people
    %% we can't fulfill their requests.
    N_PRI = error_all(PRI, econnreset),
    {next_state, destroy, State#state { proc_info = N_PRI }};
fin_sent({pkt, Pkt, {_TS, _TSDiff, RecvTime}},
	  #state { retransmit_timeout = RetransTimer } = State) ->
    ?DEBUG([node(), incoming_pkt, fin_sent, utp_proto:format_pkt(Pkt)]),

    {ok, Messages, N_PKI, N_PB, N_PRI, ZWinTimeout} =
        handle_packet_incoming(Pkt, RecvTime, State),
    N_RetransTimer = handle_retransmit_timer(Messages, RetransTimer),

    %% Calculate the next state
    N_State = State#state {
                pkt_window = N_PKI,
                pkt_buf = N_PB,
                retransmit_timeout = N_RetransTimer,
                zerowindow_timeout = ZWinTimeout,
                proc_info = N_PRI },
    case proplists:get_value(fin_sent_acked, Messages) of
        true ->
            {next_state, destroy, N_State, 0};
        undefined ->
            case proplists:get_value(got_fin, Messages) of
                true ->
                    {next_state, destroy, N_State, 0};
                undefined ->
                    {next_state, fin_sent, N_State}
            end
    end;
fin_sent({timeout, Ref, {retransmit_timeout, N}},
         #state { 
            pkt_buf = PacketBuf,
            sock_info = SockInfo,
            retransmit_timeout = Timer} = State) ->
    case handle_timeout(Ref, N, PacketBuf, SockInfo, Timer) of
        stray ->
            {next_state, fin_sent, State};
        gave_up ->
            {next_state, destroy, State, 0};
        {reinstalled, N_Timer, N_PB} ->
            {next_state, fin_sent, State#state { retransmit_timeout = N_Timer,
                                                 pkt_buf = N_PB }}
    end;
fin_sent(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, fin_sent, _Msg]),
    {next_state, fin_sent, State}.

%% @private
reset(close, State) ->
    {next_state, destroy, State, 0};
reset(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, reset, _Msg]),
    {next_state, reset, State}.

%% @private
%% Die deliberately on close for now
destroy(timeout, #state { proc_info = ProcessInfo } = State) ->
    N_ProcessInfo = error_all(ProcessInfo, econnreset),
    {stop, normal, State#state { proc_info = N_ProcessInfo }};
destroy(_Msg, State) ->
    %% Ignore messages
    ?ERR([node(), async_message, destroy, _Msg]),
    {next_state, destroy, State}.

%% @private
idle(connect,
     From, State = #state { sock_info = SockInfo,
                            pkt_buf   = PktBuf}) ->
    {Address, Port} = utp_socket:hostname_port(SockInfo),
    Conn_id_recv = utp_proto:mk_connection_id(),
    gen_utp:register_process(self(), {Conn_id_recv, Address, Port}),
    
    ConnIdSend = Conn_id_recv + 1,
    N_SockInfo = utp_socket:set_conn_id(ConnIdSend, SockInfo),

    SynPacket = mk_syn(),
    Win = utp_pkt:advertised_window(PktBuf),
    ok = utp_socket:send_pkt(Win, N_SockInfo, SynPacket, Conn_id_recv),
    {next_state, syn_sent,
     State#state {
       sock_info = N_SockInfo,
       retransmit_timeout = set_retransmit_timer(?SYN_TIMEOUT, undefined),
       pkt_buf     = utp_pkt:init_seqno(PktBuf, 2),
       connector = {From, []} }};
idle({accept, SYN}, _From, #state { sock_info = SockInfo,
                                    pkt_window = PktWin,
                                    options = Options,
                                    pkt_buf   = PktBuf } = State) ->
    Conn_id_send = SYN#packet.conn_id,
    N_SockInfo = utp_socket:set_conn_id(Conn_id_send, SockInfo),

    SeqNo = case proplists:get_value(force_seq_no, Options) of
                undefined -> utp_pkt:mk_random_seq_no();
                K -> K
            end,
    AckNo = SYN#packet.seq_no,
    1 = AckNo,

    AckPacket = #packet { ty = st_state,
			  seq_no = SeqNo,
			  ack_no = AckNo,
			  extension = ?SYN_EXTS
			},
    Win = utp_pkt:advertised_window(PktBuf),
    ok = utp_socket:send_pkt(Win, N_SockInfo, AckPacket),
    {reply, ok, connected,
            State#state { sock_info = N_SockInfo,
                          pkt_window = utp_window:handle_advertised_window(SYN, PktWin),
                          pkt_buf = utp_pkt:init_ackno(
                                      utp_pkt:init_seqno(PktBuf,
                                                         utp_pkt:bit16(SeqNo + 1)),
                                                         utp_pkt:bit16(AckNo + 1))}};

idle(_Msg, _From, State) ->
    {reply, idle, {error, enotconn}, State}.

%% @private
connected({recv, Length}, From, #state { proc_info = PI,
                                         sock_info = SockInfo,
                                         pkt_buf   = PKB } = State) ->
    PI1 = utp_process:enqueue_receiver(From, Length, PI),
    case satisfy_recvs(PI1, PKB) of
        {_, N_PRI, N_PKB} ->
            case view_zerowindow_reopen(PKB, N_PKB) of
                true ->
                    utp_pkt:handle_send_ack(SockInfo, N_PKB, [send_ack, no_piggyback]),
                    ignore;
                false ->
                    ignore
            end,
            {next_state, connected, State#state { proc_info = N_PRI,
                                                  pkt_buf   = N_PKB } }
    end;
connected({send, Data}, From, #state {
                          sock_info = SockInfo,
			  proc_info = PI,
			  pkt_window  = PKI,
                          zerowindow_timeout = ZWinTimer,
			  pkt_buf   = PKB } = State) ->
    ProcInfo = utp_process:enqueue_sender(From, Data, PI),
    {_FillMessages, N_ZWinTimer, PKB1, ProcInfo1} =
        fill_window(SockInfo,
                    ProcInfo,
                    PKI,
                    PKB,
                    ZWinTimer),
    {next_state, connected, State#state {
                              zerowindow_timeout = N_ZWinTimer,
			      proc_info = ProcInfo1,
			      pkt_buf   = PKB1 }};
connected(_Msg, _From, State) ->
    ?ERR([sync_message, connected, _Msg, _From]),
    {next_state, connected, State}.

%% @private
got_fin({recv, L}, _From, #state { pkt_buf = PktBuf,
                                   proc_info = ProcInfo } = State) ->
    true = utp_process:recv_buffer_empty(ProcInfo),
    case draining_receive(L, PktBuf) of
        {ok, Bin, N_PktBuf} ->
            {reply, {ok, Bin}, got_fin, State#state { pkt_buf = N_PktBuf}};
        empty ->
            {reply, {error, eof}, got_fin, State};
        {partial_read, Bin, N_PktBuf} ->
            {reply, {error, {partial, Bin}}, got_fin, State#state { pkt_buf = N_PktBuf}}
    end;
got_fin({send, _Data}, _From, State) ->
    {reply, {error, econnreset}, got_fin, State}.

%% @private
fin_sent({recv, L}, _From, #state { pkt_buf = PktBuf,
                                    proc_info = ProcInfo } = State) ->
    true = utp_process:recv_buffer_empty(ProcInfo),
    case draining_receive(L, PktBuf) of
        {ok, Bin, N_PktBuf} ->
            {reply, {ok, Bin}, fin_sent, State#state { pkt_buf = N_PktBuf}};
        empty ->
            {reply, {error, eof}, fin_sent, State};
        {partial_read, Bin, N_PktBuf} ->
            {reply, {error, {partial, Bin}}, fin_sent, State#state { pkt_buf = N_PktBuf}}
    end;
fin_sent({send, _Data}, _From, State) ->
    {reply, {error, econnreset}, fin_sent, State}.

%% @private
reset({recv, _L}, _From, State) ->
    {reply, {error, econnreset}, reset, State};
reset({send, _Data}, _From, State) ->
    {reply, {error, econnreset}, reset, State}.

%% @private
handle_event(_Event, StateName, State) ->
    ?ERR([unknown_handle_event, _Event, StateName, State]),
    {next_state, StateName, State}.

%% @private
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%% @private
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%% @private
terminate(_Reason, _StateName, _State) ->
    ok.

%% @private
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================

satisfy_buffer(From, 0, Res, Buffer) ->
    ?DEBUG([recv, From, byte_size(Res)]),
    reply(From, {ok, Res}),
    {ok, Buffer};
satisfy_buffer(From, Length, Res, Buffer) ->
    case utp_pkt:buffer_dequeue(Buffer) of
	{ok, Bin, N_Buffer} when byte_size(Bin) =< Length ->
	    satisfy_buffer(From, Length - byte_size(Bin), <<Res/binary, Bin/binary>>, N_Buffer);
	{ok, Bin, N_Buffer} when byte_size(Bin) > Length ->
	    <<Cut:Length/binary, Rest/binary>> = Bin,
	    satisfy_buffer(From, 0, <<Res/binary, Cut/binary>>,
			   utp_pkt:buffer_putback(Rest, N_Buffer));
	empty ->
	    {rb_drained, From, Length, Res, Buffer}
    end.

satisfy_recvs(Processes, Buffer) ->
    case utp_process:dequeue_receiver(Processes) of
	{ok, {receiver, From, Length, Res}, N_Processes} ->
	    case satisfy_buffer(From, Length, Res, Buffer) of
		{ok, N_Buffer} ->
		    satisfy_recvs(N_Processes, N_Buffer);
		{rb_drained, F, L, R, N_Buffer} ->
                    ?DEBUG([receive_buffer_drained, F, L, byte_size(R)]),
		    {rb_drained, utp_process:putback_receiver(F, L, R, N_Processes), N_Buffer}
	    end;
	empty ->
	    {ok, Processes, Buffer}
    end.

set_retransmit_timer(Timer) ->
    set_retransmit_timer(?DEFAULT_RETRANSMIT_TIMEOUT, Timer).

set_retransmit_timer(N, Timer) ->
    set_retransmit_timer(N, N, Timer).

set_retransmit_timer(N, K, undefined) ->
    Ref = gen_fsm:start_timer(N, {retransmit_timeout, K}),
    ?DEBUG([node(), setting_retransmit_timer]),
    {set, Ref};
set_retransmit_timer(N, K, {set, Ref}) ->
    gen_fsm:cancel_timer(Ref),
    N_Ref = gen_fsm:start_timer(N, {retransmit_timeout, K}),
    ?DEBUG([node(), setting_retransmit_timer]),
    {set, N_Ref}.

clear_retransmit_timer(undefined) ->
    undefined;
clear_retransmit_timer({set, Ref}) ->
    gen_fsm:cancel_timer(Ref),
    ?DEBUG([node(), clearing_retransmit_timer]),
    undefined.

handle_retransmit_timer(Messages, RetransTimer) ->
    F = fun(E, Acc) ->
                case proplists:get_value(E, Messages) of
                    true ->
                        true;
                    undefined ->
                        Acc
                end
        end,
    Analyzer = fun(L) -> lists:foldl(F, false, L) end,
    case Analyzer([recv_ack, fin_sent]) of
        true ->
            set_retransmit_timer(RetransTimer);
        false ->
            case Analyzer([all_acked]) of
                true ->
                    clear_retransmit_timer(RetransTimer);
                false ->
                    RetransTimer % Just pass it along with no update
            end
    end.

fill_window(SockInfo, ProcessInfo, WindowInfo, PktBuffer, ZWinTimer) ->
    {Messages, N_PktBuffer, N_ProcessInfo} =
        utp_pkt:fill_window(SockInfo,
                            ProcessInfo,
                            WindowInfo,
                            PktBuffer),
    case utp_window:view_zero_window(WindowInfo) of
        ok ->
            {Messages, cancel_zerowin_timer(ZWinTimer), N_PktBuffer, N_ProcessInfo};
        zero ->
            {Messages, set_zerowin_timer(ZWinTimer), N_PktBuffer, N_ProcessInfo}
    end.

cancel_zerowin_timer(undefined) ->
    undefined;
cancel_zerowin_timer({set, Ref}) ->
    gen_fsm:cancel_timer(Ref),
    undefined.

set_zerowin_timer(undefined) ->
    Ref = gen_fsm:start_timer(?ZERO_WINDOW_DELAY,
                              {zerowindow_timeout, ?ZERO_WINDOW_DELAY}),
    {set, Ref};
set_zerowin_timer({set, Ref}) -> {set, Ref}. % Already set, do nothing

mk_syn() ->
     #packet { ty = st_syn,
               seq_no = 1,
               ack_no = 0,
               extension = ?SYN_EXTS
             }. % Rest are defaults



handle_packet_incoming(Pkt, RecvTime,
                       #state {
                              pkt_buf = PB,
                              proc_info = PRI,
                              pkt_window = PKI,
                              sock_info = SockInfo,
                              zerowindow_timeout = ZWin
                             }) ->
    %% Handle the incoming packet
    try
        utp_pkt:handle_packet(RecvTime, connected, Pkt, PKI, PB)
    of
        {ok, N_PB1, N_PKI, Messages} ->

            ?DEBUG([node(), messages, Messages]),
            %% The packet may bump the advertised window from the peer, update
            N_PKI1 = utp_window:handle_advertised_window(Pkt, N_PKI),
            
            %% The incoming datagram may have payload we can deliver to an application
            {N_PRI, N_PB} =
                case satisfy_recvs(PRI, N_PB1) of
                    {ok, PR1, PB1} ->
                        {PR1, PB1};
                    {rb_drained, PR1, PB1} ->
                        %% @todo Here is the point where we should
                        %% make a check on the receive window If the
                        %% window has grown, and the last window was
                        %% 0, then immediately send out an
                        %% ACK. Otherwise install a timer.
                        {PR1, PB1}
                end,
            
            %% Fill up the send window again with the new information
            {FillMessages, ZWinTimeout, N_PB2, N_PRI2} =
                fill_window(SockInfo, N_PRI, N_PKI1, N_PB, ZWin),
            %% @todo This ACK may be cancelled if we manage to push something out
            %%       the window, etc., but the code is currently ready for it!
            %% The trick is to clear the message.

            %% Send out an ACK if needed
            utp_pkt:handle_send_ack(SockInfo, N_PB2, Messages ++ FillMessages),

            {ok, Messages, N_PKI1, N_PB2, N_PRI2, ZWinTimeout}
    catch
        throw:{error, is_far_in_future} ->
            ?DEBUG([old_packet_received]),
            {ok, [], PKI, PB, PRI, ZWin}
    end.

handle_timeout(Ref, N, PacketBuf, SockInfo, {set, Ref} = Timer) ->
    case N > ?RTO_DESTROY_VALUE of
        true ->
            gave_up;
        false ->
            N_Timer = set_retransmit_timer(N*2, Timer),
            N_PB = utp_pkt:retransmit_packet(PacketBuf, SockInfo),
            {reinstalled, N_Timer, N_PB}
    end;
handle_timeout(_Ref, _N, _PacketBuf, _Sockinfo, _Timer) ->
    ?ERR([stray_retransmit_timer, _Ref, _N, _Timer]),
    stray.

%% ----------------------------------------------------------------------

canonicalize_address(S) when is_list(S) ->
    {ok, CAddr} = inet:getaddr(S, inet),
    CAddr;
canonicalize_address({_, _, _, _} = Addr) ->
    Addr.

error_all(ProcessInfo, ErrorReason) ->
    F = fun(From) ->
                gen_fsm:reply(From, {error, ErrorReason})
        end,
    utp_process:apply_all(ProcessInfo, F),
    utp_process:mk().

-spec validate_options([term()]) -> ok | badarg.
validate_options([{backlog, N} | R]) ->
    case is_integer(N) of
        true ->
            validate_options(R);
        false ->
            badarg
    end;
validate_options([{force_seq_no, N} | R]) ->
    case is_integer(N) of
        true when N >= 0,
                  N =< 16#FFFF ->
            validate_options(R);
        true ->
            badarg;
        false ->
            badarg
    end;
validate_options([]) ->
    ok;
validate_options(_) ->
    badarg.

draining_receive(L, PktBuf) ->
    case utp_pkt:buffer_dequeue(PktBuf) of
        empty ->
            empty;
        {ok, Bin, N_Buffer} when byte_size(Bin) > L ->
            <<Cut:L/binary, Rest/binary>> = Bin,
            {ok, Cut, utp_pkt:buffer_putback(Rest, N_Buffer)};
        {ok, Bin, N_Buffer} when byte_size(Bin) == L ->
            {ok, Bin, N_Buffer};
        {ok, Bin, N_Buffer} when byte_size(Bin) < L ->
            case draining_receive(L - byte_size(Bin), N_Buffer) of
                empty ->
                    {partial_read, Bin, N_Buffer};
                {ok, Bin2, N_Buffer2} ->
                    {ok, <<Bin/binary, Bin2/binary>>, N_Buffer2};
                {partial_read, Bin2, N_Buffer} ->
                    {partial_read, <<Bin/binary, Bin2/binary>>, N_Buffer}
            end
    end.

view_zerowindow_reopen(Old, New) ->
    N = utp_pkt:advertised_window(Old),
    K = utp_pkt:advertised_window(New),
    N == 0 andalso K > 1000. % Only open up the window when we have processed a considerable amount





