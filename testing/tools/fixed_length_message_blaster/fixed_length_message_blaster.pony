use "collections"
use "files"
use "net"
use "signals"
use "time"
use "wallaroo_labs/bytes"
use "wallaroo_labs/math"
use "wallaroo_labs/options"

actor Main
  let _env: Env
  var _required_args_are_present: Bool = true
  let _timers: Timers = Timers
  let _senders: Array[Sender] = _senders.create()
  var _signal_received: Bool = false

  new create(env: Env) =>
    _env = env
    let usage = "usage: $0 --host host:port --file /path/to/file --msg-size N --batch-size N [--report-interval usec] [--time-limit usec] [--throttled-messages] [--catch_up] [--msec-interval default=1000]\n" +
    "--msg-size 0 => use file size as message size\n" +
    "--file may be list of comma-separate files, msg-size must be 0"

    try
      var h_arg: (Array[String] | None) = None
      var f_arg: (String | None) = None
      var b_arg: (USize | None) = None
      var c_arg: Bool = false
      var m_arg: (USize | None) = None
      var r_arg: U64 = 0
      var t_arg: U64 = 0
      var thr_arg: Bool = false
      var i_arg: U64 = 1000

      var options = Options(env.args)
      if env.args.size() == 1 then
        _startup_error(usage)
      end

      options
        .add("help", None, None)
        .add("host", "h", StringArgument)
        .add("file", "f", StringArgument)
        .add("batch-size", "b", I64Argument)
        .add("catch-up", None, None)
        .add("msec-interval", "i", I64Argument)
        .add("msg-size", "m", I64Argument)
        .add("report-interval", "r", I64Argument)
        .add("time-limit", "t", I64Argument)
        .add("throttled-messages", None, None)

      for option in options do
        match option
        | ("help", _) =>
          _startup_error(usage)
        | ("host", let arg: String) =>
          h_arg = arg.split(":")
        | ("file", let arg: String) =>
          f_arg = arg
        | ("batch-size", let arg: I64) =>
          b_arg = arg.usize()
        | ("cactch-up", _) =>
          c_arg = true
        | ("msec-interval", let arg: I64) =>
          i_arg = arg.u64()
        | ("msg-size", let arg: I64) =>
          m_arg = arg.usize()
        | ("report-interval", let arg: I64) =>
          r_arg = arg.u64() * 1000
        | ("time-limit", let arg: I64) =>
          t_arg = arg.u64() * 1000
        | ("throttled-messages", _) =>
          thr_arg = true
        end
      end

      if h_arg is None then
        _args_error("Must supply required '--host' argument\n" + usage)
      else
        if (h_arg as Array[String]).size() != 2 then
          _args_error("'--host' argument should be in format: '127.0.0.1:7669\n" + usage)
        end
      end

      match f_arg
      | let fp: String =>
        let path = FilePath(env.root as AmbientAuth, fp)?
        if fp.split(",").size() > 1 then
          None // defer file path processing to later
        elseif not path.exists() then
          _args_error("Error opening file " + fp)
        end
      else
        _args_error("Must supply required '--file' argument\n" + usage)
      end

      if b_arg is None then
        _args_error("Must supply required '--batch-size' argument\n" + usage)
      end

      if m_arg is None then
        _args_error("Must supply required '--msg-size' argument\n" + usage)
      end

      if _required_args_are_present then
        for file in (f_arg as String).split(",").values() do
          let batch_size = b_arg as USize
          let msg_size = m_arg as USize
          let host = h_arg as Array[String]
          let catch_up = c_arg
          let file_path = FilePath(env.root as AmbientAuth, file)?
          let msec_interval = i_arg
          let report_interval = r_arg
          let time_limit = t_arg
          let throttle_messages = thr_arg

          let batches = match OpenFile(file_path)
          | let f: File =>
            if (msg_size > 0) and ((f.size() % msg_size) != 0) then
              _startup_error("File doesn't contain " + msg_size.string() + " byte messages")
            end

            ChunkData(f, msg_size, batch_size)
          else
            _startup_error("Unable to open data file for reading")
            recover val Array[Array[U8] val] end
          end

          try
            let sender = Sender(env.root as AmbientAuth, env.err,
              host(0)?, host(1)?, batches, msec_interval,
              report_interval, throttle_messages, catch_up)
            sender.start()
            _senders.push(sender)
          else
            env.err.print("Unable to send")
          end
          let term = SignalHandler(TermHandler(this, report_interval > 0), Sig.term())
          SignalHandler(TermHandler(this, report_interval > 0), Sig.int())
          SignalHandler(TermHandler(this, report_interval > 0), Sig.hup())
          if time_limit > 0 then
            let t3 = Timer(TriggerTerm(this, report_interval > 0), time_limit, 0)
            _timers(consume t3)
          end
        end
      end
    else
      env.err.print("Unknown error occurred")
    end

  fun ref _args_error(msg: String) =>
    _env.err.print(msg)
    _required_args_are_present = false

  fun _startup_error(msg: String) =>
    @printf[I32]((msg + "\n").cstring())
    @exit[None](U8(1))

  be got_signal(verbose: Bool) =>
    // Don't trigger per-sender reports here because they'll automatically
    // happen via closed().
    if not _signal_received then
      _signal_received = true
      for sender in _senders.values() do
         sender.dispose()
      end
    end

actor Sender
  let _err: OutStream
  let _tcp: TCPConnection
  let _data_chunks: Array[Array[U8] val] val
  var _data_chunk_index: USize = 0
  let _timers: Timers = Timers
  let _msec_interval: U64
  let _report_interval: U64
  var _throttled: Bool = true
  var _count_while_throttled: USize = 0
  var _bytes_sent: USize = 0
  var _all_bytes_sent: USize = 0
  var _start_sec: I64 = 0
  var _start_nsec: I64 = 0
  let _catch_up: Bool
  var _disposed: Bool = false

  new create(ambient: AmbientAuth,
    err: OutStream,
    host: String,
    port: String,
    data_chunks: Array[Array[U8] val] val,
    msec_interval: U64,
    report_interval: U64,
    throttle_messages: Bool,
    catch_up: Bool)
  =>
    let notifier = Notifier(err, this, report_interval > 0, throttle_messages)
    _tcp = TCPConnection(ambient, consume notifier,
      host, port)
    _data_chunks = data_chunks
    _err = err
    _msec_interval = msec_interval
    _report_interval = report_interval
    _catch_up = catch_up

  be start() =>
    let t = Timer(TriggerSend(this), 0, _msec_interval * 1000*1000)
    _timers(consume t)
    if _report_interval > 0 then
      let t2 = Timer(TriggerReport(this, _report_interval > 0),
        _report_interval, _report_interval)
      _timers(consume t2)
    end

  be send() =>
    _send()

  fun ref _send() =>
    if _disposed then
      return
    end
    if not _throttled then
      _count_while_throttled = 0
      try
        let chunk = _data_chunks(_data_chunk_index)?
        _tcp.write(chunk)
        _bytes_sent = _bytes_sent + chunk.size()
        _data_chunk_index = _data_chunk_index + 1
        if _data_chunk_index >= _data_chunks.size() then
          _data_chunk_index = 0
        end
      else
        _err.print("Bug in sender")
      end
    else
      _count_while_throttled = _count_while_throttled + 1
    end

  be report(final_report: Bool, verbose: Bool) =>
    if verbose then
      @printf[I32]("i %s %lu\n".cstring(), _Time(), _bytes_sent)
    end
    _all_bytes_sent = _all_bytes_sent + _bytes_sent
    _bytes_sent = 0
    if final_report then
      _tcp.dispose()
      _timers.dispose()

      (let end_sec, let end_nsec) = Time.now()
      let elapsed_usec = ((end_sec - _start_sec) * 1000000) +
                         ((end_nsec/1000)-(_start_nsec/1000))
      if verbose then
        let mbytes_sec = (_all_bytes_sent.f64()/(1024*1024)) / (elapsed_usec.f64()/1000000)
        @printf[I32]("f %s %lu bytes %ld usec %.3f MB/sec %.3f Mbit/sec \n".cstring(),
          _Time(), _all_bytes_sent, elapsed_usec,
          mbytes_sec, mbytes_sec * 8)
      end
    end

  be throttled() =>
    _throttled = true

  be unthrottled() =>
    // We started throttled and with _start_sec == 0.
    if _start_sec == 0 then
      (_start_sec, _start_nsec) = Time.now()
    end
    _throttled = false
    if _count_while_throttled > 0 then
      if _catch_up then
        while _count_while_throttled > 0 do
          // TODO: This loop will go too fast, and we won't get a
          //       throttled message until it is far too late.
          _send()
          _count_while_throttled = _count_while_throttled - 1
        end
      else
        // We only send one extra, no matter how many send messages
        // arrived while we were throttled.
        _send()
      end
    end

  be dispose() =>
    _tcp.dispose()
    _disposed = true

class Notifier is TCPConnectionNotify
  let _err: OutStream
  let _sender: Sender
  let _verbose: Bool
  let _throttle_messages: Bool

  new iso create(err: OutStream, sender: Sender tag, verbose: Bool,
    throttle_messages: Bool) =>
    _err = err
    _sender = sender
    _verbose = verbose
    _throttle_messages = throttle_messages

  fun ref connecting(conn: TCPConnection ref, count: U32) =>
    if _verbose then
      @printf[I32]("* %s connecting %d\n".cstring(), _Time(), count)
    end

  fun ref connected(conn: TCPConnection ref) =>
    if _verbose then
      @printf[I32]("* %s connected\n".cstring(), _Time())
    end
    // The Sender starts throttled
    _sender.unthrottled()

  fun ref connect_failed(conn: TCPConnection ref) =>
    @printf[I32]("* %s unable to connect\n".cstring(), _Time())
    @exit[None](I32(1))

  fun ref closed(conn: TCPConnection ref) =>
    if _verbose then
      @printf[I32]("* %s closed\n".cstring(), _Time())
    end
    _sender.report(true, _verbose)

  fun ref throttled(conn: TCPConnection ref) =>
    if _throttle_messages then
      @printf[I32]("* %s throttled\n".cstring(), _Time())
    end
    _sender.throttled()

  fun ref unthrottled(conn: TCPConnection ref) =>
    if _throttle_messages then
      @printf[I32]("* %s unthrottled\n".cstring(), _Time())
    end
    _sender.unthrottled()

primitive ChunkData
  fun apply(f: File,
    msg_size': USize,
    batch_size: USize) : Array[Array[U8] val]  val
  =>
    let msg_size = if msg_size' > 0 then msg_size' else f.size() end
    let bytes_in_file = f.size()
    let msgs_in_file = bytes_in_file / msg_size
    let file_data: Array[U8] val = f.read(bytes_in_file)

    let bytes_needed_for_a_batch = msg_size * batch_size

    let batches_needed = Math.lcm(msgs_in_file, batch_size) / batch_size
    let bytes_in_batch = batch_size * msg_size
    let memory_needed =  batches_needed * bytes_in_batch
    let file_copies_needed = memory_needed / bytes_in_file

    var for_chunking = recover iso Array[U8] end
    for_chunking.reserve(memory_needed)

    for i in Range(0, file_copies_needed) do
      for_chunking.append(file_data)
    end

    for_chunking.truncate(memory_needed)

    let b = recover iso Array[Array[U8] val] end

    for i in Range(0, batches_needed) do
      (let c, for_chunking) = (consume for_chunking).chop(bytes_in_batch)
      b.push(consume c)
    end

    b

class TriggerSend is TimerNotify
  let _sender: Sender

  new iso create(sender: Sender) =>
    _sender = sender

  fun ref apply(timer: Timer, count: U64): Bool =>
    _sender.send()
    true

class TriggerReport is TimerNotify
  let _sender: Sender
  let _verbose: Bool

  new iso create(sender: Sender, verbose: Bool) =>
    _sender = sender
    _verbose = verbose

  fun ref apply(timer: Timer, count: U64): Bool =>
    _sender.report(false, _verbose)
    true

class TriggerTerm is TimerNotify
  let _main: Main
  let _verbose: Bool

  new iso create(main: Main, verbose: Bool) =>
    _main = main
    _verbose = verbose

  fun ref apply(timer: Timer, count: U64): Bool =>
    if _verbose then
      @printf[I32]("* %s time-limit\n".cstring(), _Time())
    end
    _main.got_signal(_verbose)
    false

class TermHandler is SignalNotify
  let _main: Main
  let _verbose: Bool

  new iso create(main: Main, verbose: Bool) =>
    _main = main
    _verbose = verbose

  fun ref apply(count: U32): Bool =>
    if _verbose then
      @printf[I32]("* %s term-handler\n".cstring(), _Time())
    end
    _main.got_signal(_verbose)
    false

class _Time
  fun apply(): Pointer[U8] =>
    (let sec, let nsec) = Time.now()
    let max: U32 = 50
    let s = @pony_alloc[Pointer[U8]](@pony_ctx[Pointer[None] iso](), max.usize())
    @snprintf[I32](s, max, "%lu.%06lu".cstring(), sec, nsec / 1000)
    s
