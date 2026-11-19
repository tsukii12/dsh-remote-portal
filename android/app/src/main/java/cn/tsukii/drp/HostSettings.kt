package cn.tsukii.drp

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class HostSettingsState(val descriptor: J = EMPTY, val catalog: J = EMPTY, val permissions: J = EMPTY,
    val devices: List<J> = emptyList(), val loading: Boolean = false, val loaded: Boolean = false,
    val busy: Boolean = false, val error: String? = null, val portalError: String? = null, val devicesLoading: Boolean = false) {
    fun namespace(name: String) = descriptor["namespaces"].array.firstOrNull { it["ns"].text == name } ?: EMPTY
    val model get() = namespace("agent-default-model")["value"]
    val definition get() = catalog["groups"].array.firstOrNull { it["id"] == model["provider"] }?.get("models")?.array?.firstOrNull { it["id"] == model["model"] } ?: EMPTY
    val permission get() = namespace("permission")["value"]["defaultPreset"].string ?: permissions["defaultPreset"].text
    val writable get() = loaded && descriptor["writable"].boolean && !loading && !busy
}

class HostSettingsStore(private val api: RPCServing) {
    private val mutable = MutableStateFlow(HostSettingsState())
    val state = mutable.asStateFlow()
    private suspend fun refresh() {
        val descriptor = api.rpc("settings/describe")
        val catalog = api.rpc("session/modelCatalog")
        val permissions = api.rpc("permissionPresets/catalog")
        mutable.value = state.value.copy(descriptor = descriptor, catalog = catalog, permissions = permissions, loaded = true)
    }
    suspend fun load() {
        if (state.value.loading || state.value.busy) return
        mutable.value = state.value.copy(loading = true, error = null)
        try { refresh() }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutable.value = state.value.copy(error = e.message) }
        finally { mutable.value = state.value.copy(loading = false) }
        loadDevices()
    }
    suspend fun loadDevices() {
        if (state.value.devicesLoading) return
        mutable.value = state.value.copy(portalError = null, devicesLoading = true)
        try {
            val devices = api.portal("devices")["devices"].array
            mutable.value = state.value.copy(devices = devices)
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutable.value = state.value.copy(portalError = e.message) }
        finally { mutable.value = state.value.copy(devicesLoading = false) }
    }
    private suspend fun mutate(ns: String, ops: List<J>) {
        val revision = state.value.namespace(ns)["revision"].long?.takeIf { it >= 0 }
        if (!state.value.writable || revision == null) {
            mutable.value = state.value.copy(error = L("These host settings are read-only or unavailable.", "这些主机设置为只读或不可用。")); return
        }
        mutable.value = state.value.copy(busy = true, error = null)
        try { api.rpc("settings/mutate", o("ns" to ns, "ops" to ops, "expectedRevision" to revision)); refresh() }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) {
            if (e is APIError.Remote && e.code == "settings/conflict") {
                val message = L("Settings changed in another client. Review the refreshed values and try again.", "设置已被其他客户端更改，请检查刷新后的值并重试。")
                try { refresh(); mutable.value = state.value.copy(error = message) }
                catch (cancel: CancellationException) { throw cancel }
                catch (reload: Exception) { mutable.value = state.value.copy(error = message + "\n" + L("Refresh failed: ", "刷新失败：") + reload.message) }
            } else mutable.value = state.value.copy(error = e.message)
        } finally { mutable.value = state.value.copy(busy = false) }
    }
    suspend fun setModel(provider: String, model: String, effort: String?) {
        mutate("agent-default-model", listOf(o("op" to "set", "path" to listOf("provider"), "value" to provider),
            o("op" to "set", "path" to listOf("model"), "value" to model),
            if (effort == null) o("op" to "unset", "path" to listOf("reasoningEffort")) else o("op" to "set", "path" to listOf("reasoningEffort"), "value" to effort)))
    }
    suspend fun setPermission(value: String) = mutate("permission", listOf(o("op" to "set", "path" to listOf("defaultPreset"), "value" to value)))
    suspend fun revokeConfirmed(id: String) {
        if (state.value.busy || state.value.loading || state.value.devicesLoading || id.isBlank() || state.value.devices.none { it["id"].text == id }) return
        mutable.value = state.value.copy(busy = true, portalError = null)
        try { api.portal("devices/revoke", body = o("id" to id)); loadDevices() }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutable.value = state.value.copy(portalError = e.message) }
        finally { mutable.value = state.value.copy(busy = false) }
    }
}
