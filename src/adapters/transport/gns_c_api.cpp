#include "gns_c_api.h"

#include <algorithm>
#include <cstring>

#include <steam/steamnetworkingsockets.h>
#include <steam/steamnetworkingsockets_flat.h>

namespace {

constexpr size_t kEventCapacity = 256;
IncGnsEvent g_events[kEventCapacity];
size_t g_event_head = 0;
size_t g_event_count = 0;
uint64_t g_dropped_events = 0;
ISteamNetworkingSockets *g_sockets = nullptr;
ISteamNetworkingUtils *g_utils = nullptr;
bool g_initialized = false;

void copy_text(char *destination, size_t capacity, const char *source) {
    if (capacity == 0) return;
    const char *safe_source = source == nullptr ? "" : source;
    const size_t length = std::min(capacity - 1, std::strlen(safe_source));
    std::memcpy(destination, safe_source, length);
    destination[length] = '\0';
}

void status_changed(SteamNetConnectionStatusChangedCallback_t *status) {
    if (g_event_count == kEventCapacity) {
        ++g_dropped_events;
        return;
    }
    const size_t index = (g_event_head + g_event_count) % kEventCapacity;
    IncGnsEvent &event = g_events[index];
    event.connection = status->m_hConn;
    event.listen_socket = status->m_info.m_hListenSocket;
    event.old_state = static_cast<int32_t>(status->m_eOldState);
    event.new_state = static_cast<int32_t>(status->m_info.m_eState);
    event.end_reason = status->m_info.m_eEndReason;
    copy_text(event.debug, sizeof(event.debug), status->m_info.m_szEndDebug);
    ++g_event_count;
}

} // namespace

extern "C" bool inc_gns_init(char *error_text, size_t error_text_capacity) {
    if (g_initialized) {
        copy_text(error_text, error_text_capacity, "already initialized");
        return false;
    }
    SteamNetworkingErrMsg error{};
    if (!GameNetworkingSockets_Init(nullptr, error)) {
        copy_text(error_text, error_text_capacity, error);
        return false;
    }
    g_sockets = SteamAPI_SteamNetworkingSockets_v009();
    g_utils = SteamAPI_SteamNetworkingUtils_v003();
    if (g_sockets == nullptr || g_utils == nullptr ||
        !SteamAPI_ISteamNetworkingUtils_SetGlobalCallback_SteamNetConnectionStatusChanged(
            g_utils,
            status_changed)) {
        GameNetworkingSockets_Kill();
        g_sockets = nullptr;
        g_utils = nullptr;
        copy_text(error_text, error_text_capacity, "failed to install connection callback");
        return false;
    }
    g_event_head = 0;
    g_event_count = 0;
    g_dropped_events = 0;
    g_initialized = true;
    if (error_text_capacity > 0) error_text[0] = '\0';
    return true;
}

extern "C" void inc_gns_shutdown(void) {
    if (!g_initialized) return;
    GameNetworkingSockets_Kill();
    g_sockets = nullptr;
    g_utils = nullptr;
    g_event_head = 0;
    g_event_count = 0;
    g_initialized = false;
}

extern "C" IncGnsListenSocket inc_gns_listen(uint16_t port, bool loopback_only) {
    if (!g_initialized || port == 0) return 0;
    SteamNetworkingIPAddr address;
    if (loopback_only) {
        address.SetIPv4(0x7f000001, port);
    } else {
        address.Clear();
        address.m_port = port;
    }
    return SteamAPI_ISteamNetworkingSockets_CreateListenSocketIP(
        g_sockets,
        address,
        0,
        nullptr);
}

extern "C" bool inc_gns_close_listen(IncGnsListenSocket socket) {
    return g_initialized && socket != 0 &&
        SteamAPI_ISteamNetworkingSockets_CloseListenSocket(g_sockets, socket);
}

extern "C" IncGnsConnection inc_gns_connect(const char *endpoint) {
    if (!g_initialized || endpoint == nullptr) return 0;
    SteamNetworkingIPAddr address;
    address.Clear();
    if (!address.ParseString(endpoint)) return 0;
    return SteamAPI_ISteamNetworkingSockets_ConnectByIPAddress(
        g_sockets,
        address,
        0,
        nullptr);
}

extern "C" bool inc_gns_accept(IncGnsConnection connection) {
    return g_initialized && connection != 0 &&
        SteamAPI_ISteamNetworkingSockets_AcceptConnection(g_sockets, connection) ==
            k_EResultOK;
}

extern "C" bool inc_gns_configure_lanes(IncGnsConnection connection) {
    if (!g_initialized || connection == 0) return false;
    // Rare control traffic must not sit behind a saturated real-time lane.
    // The remaining order favors input, snapshots, then bulk gameplay.
    const int priorities[4] = {10, 20, 30, 0};
    const uint16 weights[4] = {1, 1, 1, 1};
    return SteamAPI_ISteamNetworkingSockets_ConfigureConnectionLanes(
        g_sockets,
        connection,
        4,
        priorities,
        weights) == k_EResultOK;
}

extern "C" bool inc_gns_close(
    IncGnsConnection connection,
    int32_t reason,
    const char *debug,
    bool linger) {
    return g_initialized && connection != 0 &&
        SteamAPI_ISteamNetworkingSockets_CloseConnection(
            g_sockets,
            connection,
            reason,
            debug == nullptr ? "" : debug,
            linger);
}

extern "C" void inc_gns_run_callbacks(void) {
    if (g_initialized) SteamAPI_ISteamNetworkingSockets_RunCallbacks(g_sockets);
}

extern "C" bool inc_gns_poll_event(IncGnsEvent *event) {
    if (event == nullptr || g_event_count == 0) return false;
    *event = g_events[g_event_head];
    g_event_head = (g_event_head + 1) % kEventCapacity;
    --g_event_count;
    if (g_event_count == 0) g_event_head = 0;
    return true;
}

extern "C" uint64_t inc_gns_dropped_events(void) {
    return g_dropped_events;
}

extern "C" int32_t inc_gns_send(
    IncGnsConnection connection,
    const void *data,
    uint32_t size,
    bool reliable,
    uint16_t lane) {
    if (!g_initialized || connection == 0 || data == nullptr || size == 0 ||
        lane >= 4) return -k_EResultInvalidParam;
    SteamNetworkingMessage_t *message =
        SteamAPI_ISteamNetworkingUtils_AllocateMessage(g_utils, static_cast<int>(size));
    if (message == nullptr) return -k_EResultFail;
    std::memcpy(message->m_pData, data, size);
    message->m_conn = connection;
    message->m_nFlags = reliable
        ? k_nSteamNetworkingSend_Reliable
        : k_nSteamNetworkingSend_UnreliableNoNagle;
    message->m_idxLane = lane;
    int64_t result = -k_EResultFail;
    SteamNetworkingMessage_t *messages[1] = {message};
    SteamAPI_ISteamNetworkingSockets_SendMessages(
        g_sockets,
        1,
        messages,
        &result,
        true);
    if (result < 0) return static_cast<int32_t>(result);
    return 1;
}

extern "C" int32_t inc_gns_receive(
    IncGnsConnection connection,
    void *storage,
    uint32_t capacity,
    uint32_t *size,
    bool *reliable,
    uint16_t *lane) {
    if (!g_initialized || connection == 0 || storage == nullptr || size == nullptr ||
        reliable == nullptr || lane == nullptr) return -1;
    SteamNetworkingMessage_t *message = nullptr;
    const int count = SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection(
        g_sockets,
        connection,
        &message,
        1);
    if (count <= 0) return count;
    *size = static_cast<uint32_t>(message->m_cbSize);
    *reliable = (message->m_nFlags & k_nSteamNetworkingSend_Reliable) != 0;
    *lane = message->m_idxLane;
    if (message->m_cbSize < 0 || static_cast<uint32_t>(message->m_cbSize) > capacity) {
        SteamAPI_SteamNetworkingMessage_t_Release(message);
        return -2;
    }
    std::memcpy(storage, message->m_pData, static_cast<size_t>(message->m_cbSize));
    SteamAPI_SteamNetworkingMessage_t_Release(message);
    return 1;
}

extern "C" bool inc_gns_stats(IncGnsConnection connection, IncGnsStats *stats) {
    if (!g_initialized || connection == 0 || stats == nullptr) return false;
    SteamNetConnectionRealTimeStatus_t source{};
    if (SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus(
            g_sockets,
            connection,
            &source,
            0,
            nullptr) != k_EResultOK) return false;
    stats->ping_ms = source.m_nPing;
    stats->connection_quality_local = source.m_flConnectionQualityLocal;
    stats->connection_quality_remote = source.m_flConnectionQualityRemote;
    stats->out_packets_per_second = source.m_flOutPacketsPerSec;
    stats->out_bytes_per_second = source.m_flOutBytesPerSec;
    stats->in_packets_per_second = source.m_flInPacketsPerSec;
    stats->in_bytes_per_second = source.m_flInBytesPerSec;
    stats->pending_unreliable_bytes = source.m_cbPendingUnreliable;
    stats->pending_reliable_bytes = source.m_cbPendingReliable;
    stats->sent_unacked_reliable_bytes = source.m_cbSentUnackedReliable;
    stats->queue_time_microseconds = source.m_usecQueueTime;
    return true;
}
