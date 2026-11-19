package cn.tsukii.drp

import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

class StubAPI : RPCServing {
    val calls = mutableListOf<Pair<String, J>>()
    val streams = mutableListOf<Pair<String, J>>()
    var response: J = EMPTY
    var failure: Exception? = null
    override suspend fun rpc(method: String, args: J): J {
        calls.add(method to args); failure?.let { throw it }; return response
    }
    override fun stream(endpoint: String, args: J): Flow<J> = flow {
        streams.add(endpoint to args); awaitCancellation()
    }
}
fun fixture(name: String): J = parse(requireNotNull(StubAPI::class.java.getResource("/Fixtures/$name.json")).readText())
fun snapshot(name: String): J = fixture(name)["result"]["value"].with("type", "snapshot")
inline fun <reified T : Throwable> fails(block: () -> Unit): T {
    try { block() } catch (e: Throwable) {
        if (e is T) return e
        throw AssertionError("Expected ${T::class}, got $e", e)
    }
    throw AssertionError("Expected ${T::class}")
}
