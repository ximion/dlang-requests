module requests.streams;

private:
import std.algorithm;
import std.array;
import std.conv;
import std.experimental.logger;
import std.exception;
import std.format;
import std.range;
import std.range.primitives;
import std.string;
import std.stdio;
import std.traits;
import std.zlib;
import std.datetime;
import std.socket;
import core.stdc.errno;

import requests.buffer;

alias InDataHandler = DataPipeIface;

public class ConnectError: Exception {
    this(string message, string file =__FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow {
        super(message, file, line, next);
    }
}

class DecodingException: Exception {
    this(string message, string file =__FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow {
        super(message, file, line, next);
    }
}

public class TimeoutException: Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow {
        super(message, file, line, next);
    }
}

public class NetworkException: Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow {
        super(message, file, line, next);
    }
}

/**
 * DataPipeIface can accept some data, process, and return processed data.
 */
public interface DataPipeIface {
    /// Is there any processed data ready for reading?
    bool empty();
    /// Put next data portion for processing
    //void put(E[]);
    void put(in BufferChunk);
    /// Get any ready data
    BufferChunk get();
    /// Signal on end of incoming data stream.
    void flush();
}

/**
 * DataPipe is a pipeline of data processors, each accept some data, process it, and put result to next element in line.
 * This class used to combine different Transfer- and Content- encodings. For example: unchunk transfer-encoding "chunnked",
 * and uncompress Content-Encoding "gzip".
 */
public class DataPipe : DataPipeIface {

    DataPipeIface[] pipe;
    Buffer          buffer;
    /// Append data processor to pipeline
    /// Params:
    /// p = processor

    final void insert(DataPipeIface p) {
        pipe ~= p;
    }

    final BufferChunk[] process(DataPipeIface p, BufferChunk[] data) {
        BufferChunk[] result;
        data.each!(e => p.put(e));
        while(!p.empty()) {
            result ~= p.get();
        }
        return result;
    }
    /// Process next data portion. Data passed over pipeline and store result in buffer.
    /// Params:
    /// data = input data buffer.
    /// NoCopy means we do not copy data to buffer, we keep reference
    final void put(in BufferChunk data) {
        if ( data.empty ) {
            return;
        }
        if ( pipe.empty ) {
            buffer.put(data);
            return;
        }
        try {
            auto t = process(pipe.front, [data]);
            foreach(ref p; pipe[1..$]) {
                t = process(p, t);
            }
            while(!t.empty) {
                auto b = t[0];
                buffer.put(b);
                t.popFront();
            }
            // t.each!(b => buffer.put(b));
        }
        catch (Exception e) {
            throw new DecodingException(e.msg);
        }
    }
    /// Get what was collected in internal buffer and clear it. 
    /// Returns:
    /// data collected.
    final BufferChunk get() {
        if ( buffer.empty ) {
            return BufferChunk.init;
        }
        auto res = buffer.data;
        buffer = Buffer.init;
        return res;
    }
    alias getNoCopy = getChunks;
    ///
    /// get without datamove. but user receive [][]
    /// 
    final immutable(BufferChunk)[] getChunks() @safe pure nothrow {
        auto res = buffer.dataChunks();
        buffer = Buffer();
        return res;
    }
    /// Test if internal buffer is empty
    /// Returns:
    /// true if internal buffer is empty (nothing to get())
    final bool empty() pure const @safe @nogc nothrow {
        return buffer.empty;
    }
    final void flush() {
        BufferChunk[] product;
        foreach(ref p; pipe) {
            product.each!(e => p.put(e));
            p.flush();
            product.length = 0;
            while( !p.empty ) product ~= p.get();
        }
        product.each!(b => buffer.put(b));
    }
}

/**
 * Processor for gzipped/compressed content.
 * Also support InputRange interface.
 */
import std.zlib;

public class Decompressor : DataPipeIface {
    private {
        Buffer       __buff;
        UnCompress   __zlib;
    }
    this() {
        __buff = Buffer();
        __zlib = new UnCompress();
    }
    final override void put(in BufferChunk data) {
        if ( __zlib is null  ) {
            __zlib = new UnCompress();
        }
        __buff.put(cast(BufferChunk)__zlib.uncompress(data));
    }
    final override BufferChunk get() pure {
        assert(__buff.length);
        // auto r = __buff.__repr.__buffer[0];
        // __buff.popFrontN(r.length);
        auto r = __buff.frontChunk();
        __buff.popFrontChunk();// = __buff._chunks[1..$];
        return cast(BufferChunk)r;
    }
    final override void flush() {
        if ( __zlib is null  ) {
            return;
        }
        auto r = __zlib.flush();
        if ( r.length ) {
            __buff.put(cast(immutable(ubyte)[])r);
        }
    }
    final override @property bool empty() const pure @safe {
        debug(requests) tracef("empty=%b", __buff.empty);
        return __buff.empty;
    }
    final @property auto ref front() pure const @safe {
        debug(requests) tracef("front: buff length=%d", __buff.length);
        return __buff.front;
    }
    final @property auto popFront() pure @safe {
        debug(requests) tracef("popFront: buff length=%d", __buff.length);
        return __buff.popFront;
    }
    // final @property void popFrontN(size_t n) pure @safe {
    //     __buff.popFrontN(n);
    // }
    auto data() pure @safe @nogc nothrow {
        return __buff;
    }
}

/**
 * Unchunk chunked http responce body.
 */
public class DecodeChunked : DataPipeIface {
    //    length := 0
    //    read chunk-size, chunk-extension (if any) and CRLF
    //    while (chunk-size > 0) {
    //        read chunk-data and CRLF
    //        append chunk-data to entity-body
    //        length := length + chunk-size
    //        read chunk-size and CRLF
    //    }
    //    read entity-header
    //    while (entity-header not empty) {
    //        append entity-header to existing header fields
    //        read entity-header
    //    }
    //    Content-Length := length
    //    Remove "chunked" from Transfer-Encoding
    //

    //    Chunked-Body   = *chunk
    //                      last-chunk
    //                      trailer
    //                      CRLF
    //            
    //    chunk          = chunk-size [ chunk-extension ] CRLF
    //                     chunk-data CRLF
    //                     chunk-size     = 1*HEX
    //                     last-chunk     = 1*("0") [ chunk-extension ] CRLF
    //        
    //    chunk-extension= *( ";" chunk-ext-name [ "=" chunk-ext-val ] )
    //    chunk-ext-name = token
    //    chunk-ext-val  = token | quoted-string
    //    chunk-data     = chunk-size(OCTET)
    //    trailer        = *(entity-header CRLF)

    alias eType = ubyte;
    immutable eType[] CRLF = ['\r', '\n'];
    private {
        enum         States {huntingSize, huntingSeparator, receiving, trailer};
        char         state = States.huntingSize;
        size_t       chunk_size, to_receive;
        Buffer       buff;
        ubyte[]      linebuff;
    }
    final void put(in BufferChunk in_data) {
        BufferChunk data = in_data;
        while ( data.length ) {
            if ( state == States.trailer ) {
                to_receive = to_receive - min(to_receive, data.length);
                return;
            }
            if ( state == States.huntingSize ) {
                import std.ascii;
                ubyte[10] digits;
                int i;
                for(i=0;i<data.length;i++) {
                    ubyte v = data[i];
                    digits[i] = v;
                    if ( v == '\n' ) {
                        i+=1;
                        break;
                    }
                }
                linebuff ~= digits[0..i];
                if ( linebuff.length >= 80 ) {
                    throw new DecodingException("Can't find chunk size in the body");
                }
                data = data[i..$];
                if (!linebuff.canFind(CRLF)) {
                    continue;
                }
                chunk_size = linebuff.filter!isHexDigit.map!toUpper.map!"a<='9'?a-'0':a-'A'+10".reduce!"a*16+b";
                state = States.receiving;
                to_receive = chunk_size;
                if ( chunk_size == 0 ) {
                    to_receive = 2-min(2, data.length); // trailing \r\n
                    state = States.trailer;
                    return;
                }
                continue;
            }
            if ( state == States.receiving ) {
                if (to_receive > 0 ) {
                    auto can_store = min(to_receive, data.length);
                    buff.put(data[0..can_store]);
                    data = data[can_store..$];
                    to_receive -= can_store;
                    //tracef("Unchunked %d bytes from %d", can_store, chunk_size);
                    if ( to_receive == 0 ) {
                        //tracef("switch to huntig separator");
                        state = States.huntingSeparator;
                        continue;
                    }
                    continue;
                }
                assert(false);
            }
            if ( state == States.huntingSeparator ) {
                if ( data[0] == '\n' || data[0]=='\r') {
                    data = data[1..$];
                    continue;
                }
                state = States.huntingSize;
                linebuff.length = 0;
                continue;
            }
        }
    }
    final BufferChunk get() {
        // auto r = buff.__repr.__buffer[0];
        // buff.popFrontN(r.length);
        auto r = buff.frontChunk();
        buff.popFrontChunk();// = __buff._chunks[1..$];
        return cast(BufferChunk)r;
//        return r;
    }
    final void flush() {
    }
    final bool empty() {
        debug(requests) tracef("empty=%b", buff.empty);
        return buff.empty;
    }
    final bool done() {
        return state==States.trailer && to_receive==0;
    }
}

unittest {
    info("Testing Decompressor");
    globalLogLevel(LogLevel.info);
    alias eType = immutable(ubyte);
    eType[] gzipped = [
        0x1F, 0x8B, 0x08, 0x00, 0xB1, 0xA3, 0xEA, 0x56,
        0x00, 0x03, 0x4B, 0x4C, 0x4A, 0xE6, 0x4A, 0x49,
        0x4D, 0xE3, 0x02, 0x00, 0x75, 0x0B, 0xB0, 0x88,
        0x08, 0x00, 0x00, 0x00
    ]; // "abc\ndef\n"
    auto d = new Decompressor();
    d.put(gzipped[0..2]);
    d.put(gzipped[2..10]);
    d.put(gzipped[10..$]);
    d.flush();
    assert(equal(d.filter!(a => a!='b'), "ac\ndef\n"));
    auto e = new Decompressor();
    e.put(gzipped[0..10]);
    e.put(gzipped[10..$]);
    e.flush();
    assert(equal(e.filter!(a => a!='b'), "ac\ndef\n"));

    info("Testing DataPipe");
    auto dp = new DataPipe();
    dp.insert(new Decompressor());
    dp.put(gzipped[0..2]);
    dp.put(gzipped[2..$].dup);
    dp.flush();
    assert(equal(dp.get(), "abc\ndef\n"));

    info("Test unchunker properties");
    BufferChunk twoChunks = "2\r\n12\r\n2\r\n34\r\n0\r\n\r\n".dup.representation;
    BufferChunk[] result;
    auto uc = new DecodeChunked();
    uc.put(twoChunks);
    while(!uc.empty) {
        result ~= uc.get();
    }
    assert(equal(result[0], "12"));
    assert(equal(result[1], "34"));
    info("unchunker correctness - ok");
    //result[0][0] = '5';
    // assert(twoChunks[3] == '5');
    // info("unchunker zero copy - ok");
    info("Testing DataPipe - done");
}


/**
 * Buffer used to collect and process data from network. It remainds Appender, but support
 * also Range interface.
 * $(P To place data in buffer use put() method.)
 * $(P  To retrieve data from buffer you can use several methods:)
 * $(UL
 *  $(LI Range methods: front, back, index [])
 *  $(LI data method: return collected data (like Appender.data))
 * )
 */
static this() {
}
static ~this() {
}

public struct SSLOptions {
    enum filetype {
        pem,
        asn1,
        der = asn1,
    }
    private {
        /**
         * do we need to veryfy peer?
         */
        bool     _verifyPeer = false;
        /**
         * path to CA cert
         */
        string   _caCert;
        /**
         * path to key file (can also contain cert (for pem)
         */
        string   _keyFile;
        /**
         * path to cert file (can also contain key (for pem)
         */
        string   _certFile;
        filetype _keyType = filetype.pem;
        filetype _certType = filetype.pem;
    }
    ubyte haveFiles() pure nothrow @safe @nogc {
        ubyte r = 0;
        if ( _keyFile  ) r|=1;
        if ( _certFile ) r|=2;
        return r;
    }
    // do we want to verify peer certificates?
    bool getVerifyPeer() pure nothrow @nogc {
        return _verifyPeer;
    }
    SSLOptions setVerifyPeer(bool v) pure nothrow @nogc @safe {
        _verifyPeer = v;
        return this;
    }
    /// set key file name and type (default - pem)
    auto setKeyFile(string f, filetype t = filetype.pem) @safe pure nothrow @nogc {
        _keyFile = f;
        _keyType = t;
        return this;
    }
    auto getKeyFile() @safe pure nothrow @nogc {
        return _keyFile;
    }
    auto getKeyType() @safe pure nothrow @nogc {
        return _keyType;
    }
    /// set cert file name and type (default - pem)
    auto setCertFile(string f, filetype t = filetype.pem) @safe pure nothrow @nogc {
        _certFile = f;
        _certType = t;
        return this;
    }
    auto setCaCert(string p) @safe pure nothrow @nogc {
        _caCert = p;
        return this;
    }
    auto getCaCert() @safe pure nothrow @nogc {
        return _caCert;
    }
    auto getCertFile() @safe pure nothrow @nogc {
        return _certFile;
    }
    auto getCertType() @safe pure nothrow @nogc {
        return _certType;
    }
    /// set key file type
    void setKeyType(string t) @safe pure nothrow {
        _keyType = cast(filetype)sslKeyTypes[t];
    }
    /// set cert file type
    void setCertType(string t) @safe pure nothrow {
        _certType = cast(filetype)sslKeyTypes[t];
    }
}
static immutable int[string] sslKeyTypes;
shared static this() {
    sslKeyTypes = [
        "pem":SSLOptions.filetype.pem,
        "asn1":SSLOptions.filetype.asn1,
        "der":SSLOptions.filetype.der,
    ];
}

version(vibeD) {
}
else {
    extern(C) {
        int SSL_library_init();
        void OpenSSL_add_all_ciphers();
        void OpenSSL_add_all_digests();
        void SSL_load_error_strings();

        struct SSL {}
        struct SSL_CTX {}
        struct SSL_METHOD {}

        SSL_CTX* SSL_CTX_new(const SSL_METHOD* method);
        SSL* SSL_new(SSL_CTX*);
        int SSL_set_fd(SSL*, int);
        int SSL_connect(SSL*);
        int SSL_write(SSL*, const void*, int);
        int SSL_read(SSL*, void*, int);
        int SSL_shutdown(SSL*) @trusted @nogc nothrow;
        void SSL_free(SSL*);
        void SSL_CTX_free(SSL_CTX*);

        long SSL_CTX_ctrl(SSL_CTX *ctx, int cmd, long larg, void *parg);

        long SSL_CTX_set_mode(SSL_CTX *ctx, long mode);
        int  SSL_CTX_set_default_verify_paths(SSL_CTX *ctx);
        int SSL_CTX_load_verify_locations(SSL_CTX *ctx, const char *CAfile, const char *CApath);
        void SSL_CTX_set_verify(SSL_CTX *ctx, int mode, void *);
        long SSL_set_mode(SSL *ssl, long mode);
        int  SSL_CTX_use_PrivateKey_file(SSL_CTX *ctx, const char *file, int type);
        int  SSL_CTX_use_certificate_file(SSL_CTX *ctx, const char *file, int type);

        long SSL_CTX_get_mode(SSL_CTX *ctx);
        long SSL_get_mode(SSL *ssl);

        long ERR_get_error();
        char* ERR_reason_error_string(ulong e);

        SSL_METHOD* SSLv3_client_method();
        SSL_METHOD* TLSv1_2_client_method();
        SSL_METHOD* TLSv1_client_method();
    }

    enum SSL_VERIFY_PEER = 0x01;
    enum SSL_FILETYPE_PEM = 1;
    enum SSL_FILETYPE_ASN1 = 2;

    immutable int[SSLOptions.filetype] ft2ssl;

    shared static this() {
        SSL_library_init();
        OpenSSL_add_all_ciphers();
        OpenSSL_add_all_digests();
        SSL_load_error_strings();
        ft2ssl = [
            SSLOptions.filetype.pem: SSL_FILETYPE_PEM,
            SSLOptions.filetype.asn1: SSL_FILETYPE_ASN1,
            SSLOptions.filetype.der: SSL_FILETYPE_ASN1
        ];
    }

    public class OpenSslSocket : Socket {
        //enum SSL_MODE_RELEASE_BUFFERS = 0x00000010L;
        private SSL* ssl;
        private SSL_CTX* ctx;
        private void initSsl(SSLOptions opts) {
            //ctx = SSL_CTX_new(SSLv3_client_method());
            ctx = SSL_CTX_new(TLSv1_client_method());
            assert(ctx !is null);
            if ( opts.getVerifyPeer() ) {
                SSL_CTX_set_default_verify_paths(ctx);
                if ( opts.getCaCert() ) {
                    SSL_CTX_load_verify_locations(ctx, opts.getCaCert().toStringz(), null);
                }
                SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, null);
            }
            immutable keyFile = opts.getKeyFile();
            immutable keyType = opts.getKeyType();
            immutable certFile = opts.getCertFile();
            immutable certType = opts.getCertType();
            final switch(opts.haveFiles()) {
                case 0b11:  // both files
                    SSL_CTX_use_PrivateKey_file(ctx,  keyFile.toStringz(), ft2ssl[keyType]);
                    SSL_CTX_use_certificate_file(ctx, certFile.toStringz(),ft2ssl[certType]);
                    break;
                case 0b01:  // key only
                    SSL_CTX_use_PrivateKey_file(ctx,  keyFile.toStringz(), ft2ssl[keyType]);
                    SSL_CTX_use_certificate_file(ctx, keyFile.toStringz(), ft2ssl[keyType]);
                    break;
                case 0b10:  // cert only
                    SSL_CTX_use_PrivateKey_file(ctx,  certFile.toStringz(), ft2ssl[certType]);
                    SSL_CTX_use_certificate_file(ctx, certFile.toStringz(), ft2ssl[certType]);
                    break;
                case 0b00:
                    break;
            }
            //SSL_CTX_set_mode(ctx, SSL_MODE_RELEASE_BUFFERS);
            //SSL_CTX_ctrl(ctx, 33, SSL_MODE_RELEASE_BUFFERS, null);
            ssl = SSL_new(ctx);
            SSL_set_fd(ssl, this.handle);
        }

        @trusted
        override void connect(Address dest) {
            super.connect(dest);
            if(SSL_connect(ssl) == -1) {
                throw new Exception("ssl connect failed: %s".format(to!string(ERR_reason_error_string(ERR_get_error()))));
            }
        }

        @trusted
        override ptrdiff_t send(const(void)[] buf, SocketFlags flags) {
            return SSL_write(ssl, buf.ptr, cast(uint) buf.length);
        }
        override ptrdiff_t send(const(void)[] buf) {
            return send(buf, SocketFlags.NONE);
        }
        @trusted
        override ptrdiff_t receive(void[] buf, SocketFlags flags) {
            return SSL_read(ssl, buf.ptr, cast(int)buf.length);
        }
        override ptrdiff_t receive(void[] buf) {
            return receive(buf, SocketFlags.NONE);
        }
        this(AddressFamily af, SocketType type = SocketType.STREAM, SSLOptions opts = SSLOptions()) {
            super(af, type);
            initSsl(opts);
        }

        this(socket_t sock, AddressFamily af) {
            super(sock, af);
            initSsl(SSLOptions());
        }
        override void close() {
            //SSL_shutdown(ssl);
            super.close();
        }
        ~this() {
            SSL_free(ssl);
            SSL_CTX_free(ctx);
        }
    }

    public class SSLSocketStream: SocketStream {
        SSLOptions _sslOptions;

        this(SSLOptions opts) {
            _sslOptions = opts;
        }

        override void open(AddressFamily fa) {
            if ( s !is null ) {
                s.close();
            }
            s = new OpenSslSocket(fa, SocketType.STREAM, _sslOptions);
            assert(s !is null, "Can't create socket");
            __isOpen = true;
        }
        override SSLSocketStream accept() {
            auto newso = s.accept();
            if ( s is null ) {
                return null;
            }
            auto newstream = new SSLSocketStream(_sslOptions);
            auto sslSocket = new OpenSslSocket(newso.handle, s.addressFamily);
            newstream.s = sslSocket;
            newstream.__isOpen = true;
            newstream.__isConnected = true;
            return newstream;
        }
    }
}

public interface NetworkStream {
    @property bool isConnected() const;
    @property bool isOpen() const;

    void close() @trusted;

    ///
    /// timeout is the socket write timeout.
    ///
    NetworkStream connect(string host, ushort port, Duration timeout = 10.seconds);

    ptrdiff_t send(const(void)[] buff);
    ptrdiff_t receive(void[] buff);

    NetworkStream accept();
    @property void reuseAddr(bool);
    void bind(Address);
    void listen(int);

    ///
    /// Set timeout for receive calls. 0 means no timeout.
    ///
    @property void readTimeout(Duration timeout);
}

public abstract class SocketStream : NetworkStream {
    private {
        Duration timeout;
        Socket   s;
        bool     __isOpen;
        bool     __isConnected;
    }
    void open(AddressFamily fa) {
    }
    @property ref Socket so() @safe pure {
        return s;
    }
    @property bool isOpen() @safe @nogc pure const {
        return s && __isOpen;
    }
    @property bool isConnected() @safe @nogc pure const {
        return s && __isOpen && __isConnected;
    }
    void close() @trusted {
        debug(requests) tracef("Close socket");
        if ( isOpen ) {
            s.close();
            __isOpen = false;
            __isConnected = false;
        }
        s = null;
    }
    
    SocketStream connect(string host, ushort port, Duration timeout = 10.seconds) {
        debug(requests) tracef(format("Create connection to %s:%d", host, port));
        Address[] addresses;
        __isConnected = false;
        try {
            addresses = getAddress(host, port);
        } catch (Exception e) {
            throw new ConnectError("Can't resolve name when connect to %s:%d: %s".format(host, port, e.msg));
        }
        foreach(a; addresses) {
            debug(requests) tracef("Trying %s", a);
            try {
                open(a.addressFamily);
                s.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, timeout);
                s.connect(a);
                debug(requests) tracef("Connected to %s", a);
                __isConnected = true;
                break;
            } catch (SocketException e) {
                warningf("Failed to connect to %s:%d(%s): %s", host, port, a, e.msg);
                s.close();
            }
        }
        if ( !__isConnected ) {
            throw new ConnectError("Can't connect to %s:%d".format(host, port));
        }
        return this;
    }
    
    ptrdiff_t send(const(void)[] buff) @safe
    in {assert(isConnected);}
    body {
        auto rc = s.send(buff);
        if (rc < 0) {
            close();
            throw new NetworkException("sending data");
        }
        return rc;
    }
    
    ptrdiff_t receive(void[] buff) @safe {
        while (true) {
            auto r = s.receive(buff);
            if (r < 0) {
                version(Windows) {
                    close();
                    if ( errno == 0 ) {
                        throw new TimeoutException("Timeout receiving data");
                    }
                    throw new NetworkException("receiving data");
                }
                version(Posix) {
                    if ( errno == EINTR ) {
                        continue;
                    }
                    close();
                    if ( errno == EAGAIN ) {
                        throw new TimeoutException("Timeout receiving data");
                    }
                    throw new NetworkException("receiving data");
                }
            }
            else {
                buff.length = r;
            }
            return r;
        }
        assert(false);
    }

    @property void readTimeout(Duration timeout) @safe {
        s.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, timeout);
    }
    override SocketStream accept() {
        assert(false, "Implement before use");
    }
    @property override void reuseAddr(bool yes){
        if (yes) {
            s.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
        }
        else {
            s.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 0);
        }
    }
    override void bind(Address addr){
        s.bind(addr);
    }
    override void listen(int n) {
        s.listen(n);
    };
}

public class TCPSocketStream : SocketStream {
    override void open(AddressFamily fa) {
        if ( s !is null ) {
            s.close();
        }
        s = new Socket(fa, SocketType.STREAM, ProtocolType.TCP);
        assert(s !is null, "Can't create socket");
        __isOpen = true;
        s.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
    }
    override TCPSocketStream accept() {
        auto newso = s.accept();
        if ( s is null ) {
            return null;
        }
        auto newstream = new TCPSocketStream();
        newstream.s = newso;
        newstream.__isOpen = true;
        newstream.__isConnected = true;
        newstream.s.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
        return newstream;
    }
}

version (vibeD) {
    import vibe.core.net, vibe.stream.tls;

    public class TCPVibeStream : NetworkStream {
    private:
        TCPConnection _conn;
        Duration _readTimeout = Duration.max;
        bool _isOpen = true;

    public:
        @property bool isConnected() const {
            return _conn.connected;
        }
        @property override bool isOpen() const {
            return _conn && _isOpen;
        }
        void close() @trusted {
            _conn.close();
            _isOpen = false;
        }

        NetworkStream connect(string host, ushort port, Duration timeout = 10.seconds) {
            // FIXME: timeout not supported in vibe.d
            try {
                _conn = connectTCP(host, port);
            }
            catch (Exception e)
                throw new ConnectError("Can't connect to %s:%d".format(host, port), __FILE__, __LINE__, e);

            return this;
        }

        ptrdiff_t send(const(void)[] buff) {
            _conn.write(cast(const(ubyte)[])buff);
            return buff.length;
        }

        ptrdiff_t receive(void[] buff) {
            if (!_conn.waitForData(_readTimeout)) {
                if (!_conn.connected) {
                    return 0;
                }
                throw new TimeoutException("Timeout receiving data");
            }

            if(_conn.empty) {
                return 0;
            }

            auto chunk = min(_conn.leastSize, buff.length);
            assert(chunk != 0);
            _conn.read(cast(ubyte[])buff[0 .. chunk]);
            return chunk;
        }

        @property void readTimeout(Duration timeout) {
            if (timeout == 0.seconds) {
                _readTimeout = Duration.max;
            }
            else {
                _readTimeout = timeout;
            }
        }
        override TCPVibeStream accept() {
            assert(false, "Must be implemented");
        }
        override @property void reuseAddr(bool){
            assert(false, "Not Implemented");
        }
        override void bind(Address){
            assert(false, "Not Implemented");
        }
        override void listen(int){
            assert(false, "Not Implemented");
        }
    }

    public class SSLVibeStream : TCPVibeStream {
    private:
        Stream _sslStream;
        bool   _isOpen = true;
        SSLOptions _sslOptions;

    public:
        this(SSLOptions opts) {
            _sslOptions = opts;
        }
        override NetworkStream connect(string host, ushort port, Duration timeout = 10.seconds) {
            try {
                _conn = connectTCP(host, port);
                auto sslctx = createTLSContext(TLSContextKind.client);
                if ( _sslOptions.getVerifyPeer() ) {
                    if ( _sslOptions.getCaCert() == null ) {
                        throw new ConnectError("With vibe.d you have to call setCaCert() before verify server certificate.");
                    }
                    sslctx.useTrustedCertificateFile(_sslOptions.getCaCert());
                    sslctx.peerValidationMode = TLSPeerValidationMode.trustedCert;
                } else {
                    sslctx.peerValidationMode = TLSPeerValidationMode.none;
                }
                immutable keyFile = _sslOptions.getKeyFile();
                immutable certFile = _sslOptions.getCertFile();
                final switch(_sslOptions.haveFiles()) {
                    case 0b11:  // both files
                        sslctx.usePrivateKeyFile(keyFile);
                        sslctx.useCertificateChainFile(certFile);
                        break;
                    case 0b01:  // key only
                        sslctx.usePrivateKeyFile(keyFile);
                        sslctx.useCertificateChainFile(keyFile);
                        break;
                    case 0b10:  // cert only
                        sslctx.usePrivateKeyFile(certFile);
                        sslctx.useCertificateChainFile(certFile);
                        break;
                    case 0b00:
                        break;
                }
                _sslStream = createTLSStream(_conn, sslctx, host);
            }
            catch (ConnectError e) {
                throw e;
            }
            catch (Exception e) {
                throw new ConnectError("Can't connect to %s:%d".format(host, port), __FILE__, __LINE__, e);
            }

            return this;
        }

        override ptrdiff_t send(const(void)[] buff) {
            _sslStream.write(cast(const(ubyte)[])buff);
            return buff.length;
        }

        override ptrdiff_t receive(void[] buff) {
            if (!_sslStream.dataAvailableForRead) {
                if (!_conn.waitForData(_readTimeout)) {
                    if (!_conn.connected) {
                        return 0;
                    }
                    throw new TimeoutException("Timeout receiving data");
                }
            }

            if(_sslStream.empty) {
                return 0;
            }

            auto chunk = min(_sslStream.leastSize, buff.length);
            assert(chunk != 0);
            _sslStream.read(cast(ubyte[])buff[0 .. chunk]);
            return chunk;
        }

        override void close() @trusted {
            _sslStream.finalize();
            _conn.close();
            _isOpen = false;
        }
        @property override bool isOpen() const {
            return _conn && _isOpen;
        }
        override SSLVibeStream accept() {
            assert(false, "Must be implemented");
        }
        override @property void reuseAddr(bool){
            assert(false, "Not Implemented");
        }
        override void bind(Address){
            assert(false, "Not Implemented");
        }
        override void listen(int){
            assert(false, "Not Implemented");
        }
    }
}

version (vibeD) {
    public alias TCPStream = TCPVibeStream;
    public alias SSLStream = SSLVibeStream;
}
else {
    public alias TCPStream = TCPSocketStream;
    public alias SSLStream = SSLSocketStream;
}
