package cn.tsukii.drp

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class HostSettingsTests {
    private class API : RPCServing {
        var revision = 7L
        var writable = true
        var missing = false
        var readError = false
        var conflict = false
        var failConflictRefresh = false
        var rejected = false
        var portalFailure = false
        val calls = mutableListOf<Pair<String, J>>()
        val portals = mutableListOf<Pair<String, J?>>()
        override fun stream(endpoint: String, args: J): Flow<J> = emptyFlow()
        override suspend fun rpc(method: String, args: J): J {
            calls += method to args
            return when (method) {
                "settings/describe" -> {
                    if (readError) throw PortalError("read failed")
                    o("writable" to writable, "namespaces" to if (missing) emptyList<J>() else listOf(
                        o("ns" to "agent-default-model", "revision" to revision, "value" to o("provider" to "P", "model" to "M", "reasoningEffort" to "high")),
                        o("ns" to "permission", "revision" to revision, "value" to o("defaultPreset" to "workspace-write"))))
                }
                "settings/mutate" -> {
                    if (conflict) { revision++; readError = failConflictRefresh; throw APIError.Remote("settings/conflict", "conflict") }
                    if (rejected) throw APIError.Remote("settings/rejected", "rejected")
                    revision++; EMPTY
                }
                "session/modelCatalog" -> o("groups" to emptyList<J>(), "failures" to emptyList<J>())
                "permissionPresets/catalog" -> o("defaultPreset" to "workspace-write")
                else -> error(method)
            }
        }
        override suspend fun portal(path: String, query: Map<String, String>, body: J?): J {
            portals += path to body
            if (portalFailure) throw PortalError("devices unavailable")
            return o("ok" to true, "devices" to listOf(o("id" to "current"), o("id" to "other")))
        }
    }
    @Test fun defaultsUseExactRevisionCheckedModelEffortAndPermissionMutations() = runTest {
        val api = API(); val store = HostSettingsStore(api); store.load()
        assertTrue(store.state.value.writable); assertEquals("workspace-write", store.state.value.permission)
        assertEquals(EMPTY, store.state.value.definition)
        assertEquals(listOf("settings/describe", "session/modelCatalog", "permissionPresets/catalog"), api.calls.map { it.first })
        store.setModel("P", "M", null)
        assertEquals(o("ns" to "agent-default-model", "expectedRevision" to 7L, "ops" to listOf(
            o("op" to "set", "path" to listOf("provider"), "value" to "P"), o("op" to "set", "path" to listOf("model"), "value" to "M"),
            o("op" to "unset", "path" to listOf("reasoningEffort")))), api.calls.first { it.first == "settings/mutate" }.second)
        store.setModel("P", "M", "high")
        assertEquals(o("op" to "set", "path" to listOf("reasoningEffort"), "value" to "high"), api.calls.last { it.first == "settings/mutate" }.second["ops"].array.last())
        store.setPermission("read-only")
        assertEquals(o("ns" to "permission", "expectedRevision" to 9L, "ops" to listOf(o("op" to "set", "path" to listOf("defaultPreset"), "value" to "read-only"))), api.calls.last { it.first == "settings/mutate" }.second)
        assertFalse(store.state.value.busy)
    }
    @Test fun conflictsRefreshAndRequireAnExplicitRetryInsteadOfReplayingAWrite() = runTest {
        val api = API(); val store = HostSettingsStore(api); store.load(); api.conflict = true
        store.setPermission("read-only")
        assertEquals(8L, store.state.value.namespace("permission")["revision"].long)
        assertTrue(store.state.value.error!!.contains("another client")); assertFalse(store.state.value.busy)
        assertEquals(1, api.calls.count { it.first == "settings/mutate" })
        api.failConflictRefresh = true; store.setPermission("read-only")
        assertTrue(store.state.value.error!!.contains("Refresh failed"))
    }
    @Test fun unavailableReadOnlyEmptyAndRejectedSettingsHaveErrorsWithoutUnversionedWrites() = runTest {
        for (mode in listOf("unloaded", "readonly", "missing", "read-error")) {
            val api = API(); api.writable = mode != "readonly"; api.missing = mode == "missing"; api.readError = mode == "read-error"
            val store = HostSettingsStore(api); if (mode != "unloaded") store.load()
            store.setPermission("read-only")
            assertNotNull(store.state.value.error); assertTrue(api.calls.none { it.first == "settings/mutate" })
        }
        val api = API(); val store = HostSettingsStore(api); store.load(); api.rejected = true
        store.setPermission("read-only"); assertEquals("rejected", store.state.value.error); assertFalse(store.state.value.busy)
    }
    @Test fun devicesAreReadOnlyUntilAnExplicitKnownDeviceIsConfirmedAndFailuresCanReload() = runTest {
        val api = API(); val store = HostSettingsStore(api); store.load()
        assertEquals(listOf("devices" to null), api.portals)
        store.revokeConfirmed(""); store.revokeConfirmed("unknown"); assertEquals(1, api.portals.size)
        store.revokeConfirmed("other")
        assertEquals("devices/revoke" to o("id" to "other"), api.portals[1]); assertEquals("devices", api.portals[2].first)
        assertTrue(api.portals.none { it.second == o("id" to "current") })
        api.portalFailure = true; store.loadDevices(); assertEquals("devices unavailable", store.state.value.portalError)
        api.portalFailure = false; store.loadDevices(); assertNull(store.state.value.portalError)
    }
}
