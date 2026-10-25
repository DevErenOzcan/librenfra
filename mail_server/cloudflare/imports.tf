# Adopts the routing rule that existed before this configuration - eren.ozcan@
# forwarded to the owner's own mailbox - instead of creating a second one.
# Once it is in the state this block does nothing.
#
# Setting up from nothing, with no such rule in Email Routing, delete this
# file first: an import of a rule that does not exist fails the plan.
import {
  to = cloudflare_email_routing_rule.forward["eren.ozcan@deverenozcan.com"]
  id = "${local.zone_id}/e475da2fcdd349759b81e434dc97e8c0"
}
