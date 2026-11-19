package cn.tsukii.drp

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import okhttp3.*
import okio.Buffer
import okio.ForwardingSource
import okio.Timeout
import okio.buffer
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@OptIn(ExperimentalCoroutinesApi::class)
class ConnectionCancellationTests {
    @Test fun cancelledDeliveryClosesResponseOffTheCallingThread() = runTest {
        val closed = CountDownLatch(1)
        val thread = AtomicReference<Thread>()
        val caller = Thread.currentThread()
        val source = object : ForwardingSource(Buffer()) {
            override fun close() { thread.set(Thread.currentThread()); closed.countDown(); super.close() }
        }.buffer()
        val request = Request.Builder().url("http://localhost/").build()
        lateinit var callback: Callback
        var cancelled = false
        val call = object : Call {
            override fun request() = request
            override fun execute(): Response = error("unused")
            override fun enqueue(responseCallback: Callback) { callback = responseCallback }
            override fun cancel() { cancelled = true }
            override fun isExecuted() = true
            override fun isCanceled() = cancelled
            override fun timeout() = Timeout.NONE
            override fun clone(): Call = error("unused")
        }
        val response = Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(object : ResponseBody() {
            override fun contentType(): MediaType? = null
            override fun contentLength() = 0L
            override fun source() = source
        }).build()
        val job = launch(start = CoroutineStart.UNDISPATCHED) { call.await().close() }
        callback.onResponse(call, response)
        job.cancel()
        runCurrent()
        assertTrue(closed.await(3, TimeUnit.SECONDS))
        assertTrue(cancelled)
        assertNotSame(caller, thread.get())
        job.join()
    }
}
