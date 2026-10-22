/* Owned optional-backend regression: a retired writable callback identity
 * must remain comparison-only while live component chains are inspected. */
#include "agent-priv.h"
#include "component.h"
#include "socket/udp-bsd.h"
#include <sys/mman.h>
#include <unistd.h>
#include <stdio.h>

extern void _tcp_sock_is_writable (NiceSocket *, gpointer);

int main (void) {
  GMainContext *context = g_main_context_new ();
  NiceAgent *agent = nice_agent_new (context, NICE_COMPATIBILITY_RFC5245);
  guint id = nice_agent_add_stream (agent, 1);
  NiceStream *stream = NULL;
  NiceComponent *component = NULL;
  agent_lock (agent);
  g_assert (agent_find_component (agent, id, 1, &stream, &component));
  NiceAddress address;
  nice_address_init (&address);
  g_assert (nice_address_set_from_string (&address, "127.0.0.1"));
  nice_address_set_port (&address, 0);
  NiceSocket *live = nice_udp_bsd_socket_new (&address, NULL);
  g_assert (live != NULL);
  nice_component_attach_socket (component, live);
  agent_unlock (agent);

  /* A genuinely inaccessible retired address, not a mock socket object. The
   * old unconditional resume dereference faults here. Owned-chain membership
   * safely ignores it with a live socket present and after stream teardown. */
  size_t page = (size_t) sysconf (_SC_PAGESIZE);
  void *retired = mmap (NULL, page, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
  g_assert (retired != MAP_FAILED);
  _tcp_sock_is_writable (retired, component);
  agent_lock (agent);
  nice_component_free_socket_sources (component);
  agent_unlock (agent);
  _tcp_sock_is_writable (retired, component);
  munmap (retired, page);
  nice_agent_remove_stream (agent, id);
  g_object_unref (agent);
  g_main_context_unref (context);
  puts ("PASS owned TLS writable callback ignores inaccessible retired identity through live and retired socket-source ownership");
  return 0;
}
