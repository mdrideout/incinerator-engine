#ifndef INCINERATOR_GNS_C_API_H
#define INCINERATOR_GNS_C_API_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t IncGnsConnection;
typedef uint32_t IncGnsListenSocket;

enum IncGnsState {
    INC_GNS_NONE = 0,
    INC_GNS_CONNECTING = 1,
    INC_GNS_FINDING_ROUTE = 2,
    INC_GNS_CONNECTED = 3,
    INC_GNS_CLOSED_BY_PEER = 4,
    INC_GNS_PROBLEM_DETECTED_LOCALLY = 5,
};

typedef struct IncGnsEvent {
    IncGnsConnection connection;
    IncGnsListenSocket listen_socket;
    int32_t old_state;
    int32_t new_state;
    int32_t end_reason;
    char debug[128];
} IncGnsEvent;

typedef struct IncGnsStats {
    int32_t ping_ms;
    float connection_quality_local;
    float connection_quality_remote;
    float out_packets_per_second;
    float out_bytes_per_second;
    float in_packets_per_second;
    float in_bytes_per_second;
    int32_t pending_unreliable_bytes;
    int32_t pending_reliable_bytes;
    int32_t sent_unacked_reliable_bytes;
    int64_t queue_time_microseconds;
} IncGnsStats;

bool inc_gns_init(char *error_text, size_t error_text_capacity);
void inc_gns_shutdown(void);
IncGnsListenSocket inc_gns_listen(uint16_t port, bool loopback_only);
bool inc_gns_close_listen(IncGnsListenSocket socket);
IncGnsConnection inc_gns_connect(const char *endpoint);
bool inc_gns_accept(IncGnsConnection connection);
bool inc_gns_configure_lanes(IncGnsConnection connection);
bool inc_gns_close(
    IncGnsConnection connection,
    int32_t reason,
    const char *debug,
    bool linger
);
void inc_gns_run_callbacks(void);
bool inc_gns_poll_event(IncGnsEvent *event);
uint64_t inc_gns_dropped_events(void);
int32_t inc_gns_send(
    IncGnsConnection connection,
    const void *data,
    uint32_t size,
    bool reliable,
    uint16_t lane
);
int32_t inc_gns_receive(
    IncGnsConnection connection,
    void *storage,
    uint32_t capacity,
    uint32_t *size,
    bool *reliable,
    uint16_t *lane
);
bool inc_gns_stats(IncGnsConnection connection, IncGnsStats *stats);

#ifdef __cplusplus
}
#endif

#endif
