# Plans against a mock provider: checks what Terraform would set up on
# Cloudflare without an account, a token or a state. From cloudflare/:
#   terraform init && terraform test

mock_provider "cloudflare" {
  mock_data "cloudflare_zone" {
    defaults = {
      zone_id = "0123456789abcdef0123456789abcdef"
      account = { id = "fedcba9876543210fedcba9876543210", name = "test" }
    }
  }
}

# imports.tf adopts an existing rule; a mock provider cannot import, so the
# test stands in for it.
override_resource {
  target = cloudflare_email_routing_rule.forward["eren.ozcan@deverenozcan.com"]
}

variables {
  cloudflare_api_token = "not-used-by-the-mock"
  fallback_address     = "fallback@example.com"
}

# With route_all_mail = false (and no test_address) the server gets no mail:
# no catch-all, no test rule.
run "leaves_email_routing_alone_when_asked" {
  command = plan

  variables {
    route_all_mail = false
  }

  assert {
    condition     = length(cloudflare_email_routing_rule.test) == 0 && length(cloudflare_email_routing_catch_all.all) == 0
    error_message = "With route_all_mail false and no test_address, nothing may route to the server."
  }

  assert {
    condition = (
      cloudflare_zero_trust_tunnel_cloudflared_config.mail.config.ingress[0].hostname == "mx-in.deverenozcan.com" &&
      cloudflare_zero_trust_tunnel_cloudflared_config.mail.config.ingress[0].service == "http://127.0.0.1:8025" &&
      cloudflare_zero_trust_tunnel_cloudflared_config.mail.config.ingress[1].hostname == "mail.deverenozcan.com" &&
      cloudflare_zero_trust_tunnel_cloudflared_config.mail.config.ingress[1].service == "http://127.0.0.1:8080" &&
      cloudflare_zero_trust_tunnel_cloudflared_config.mail.config.ingress[2].service == "http_status:404"
    )
    error_message = "The tunnel must send mx-in to the receiver on 127.0.0.1:8025, mail to webmail on 127.0.0.1:8080, and nothing else anywhere."
  }

  assert {
    condition     = cloudflare_dns_record.webmail.type == "CNAME" && cloudflare_dns_record.webmail.proxied && cloudflare_dns_record.webmail.name == "mail.deverenozcan.com"
    error_message = "mail must be a proxied CNAME to the tunnel."
  }

  assert {
    condition     = cloudflare_dns_record.inbound.type == "CNAME" && cloudflare_dns_record.inbound.proxied && cloudflare_dns_record.inbound.name == "mx-in.deverenozcan.com"
    error_message = "mx-in must be a proxied CNAME to the tunnel."
  }

  assert {
    condition = (
      cloudflare_zero_trust_access_application.inbound.domain == "mx-in.deverenozcan.com" &&
      cloudflare_zero_trust_access_policy.worker.decision == "non_identity" &&
      length(cloudflare_zero_trust_access_policy.worker.include) == 1 &&
      cloudflare_zero_trust_access_service_token.worker.duration == "forever"
    )
    error_message = "Access must let the Worker's service token, and only that, through to mx-in; the token must not expire."
  }

  assert {
    condition = (
      one([for b in cloudflare_workers_script.inbound.bindings : b.text if b.name == "RECEIVER_URL"]) == "https://mx-in.deverenozcan.com/inbound" &&
      one([for b in cloudflare_workers_script.inbound.bindings : b.type if b.name == "RECEIVER_SECRET"]) == "secret_text" &&
      one([for b in cloudflare_workers_script.inbound.bindings : b.type if b.name == "ACCESS_CLIENT_SECRET"]) == "secret_text"
    )
    error_message = "The Worker must post to the receiver's URL and hold its credentials as secrets."
  }
}

run "routes_one_address_for_testing" {
  command = plan

  variables {
    route_all_mail = false
    test_address   = "test@deverenozcan.com"
  }

  assert {
    condition = (
      length(cloudflare_email_routing_catch_all.all) == 0 &&
      cloudflare_email_routing_rule.test[0].matchers[0].type == "literal" &&
      cloudflare_email_routing_rule.test[0].matchers[0].value == "test@deverenozcan.com" &&
      cloudflare_email_routing_rule.test[0].actions[0].type == "worker" &&
      cloudflare_email_routing_rule.test[0].actions[0].value[0] == "mail-inbound"
    )
    error_message = "test_address must send that one address, and only it, to the Worker."
  }
}

# The default since the switch-over: every address to the server, except
# the ones forwarded straight to the fallback mailbox.
run "routes_every_address_by_default" {
  command = plan

  assert {
    condition = (
      cloudflare_email_routing_rule.forward["eren.ozcan@deverenozcan.com"].enabled &&
      cloudflare_email_routing_rule.forward["eren.ozcan@deverenozcan.com"].matchers[0].value == "eren.ozcan@deverenozcan.com" &&
      cloudflare_email_routing_rule.forward["eren.ozcan@deverenozcan.com"].actions[0].type == "forward" &&
      cloudflare_email_routing_rule.forward["eren.ozcan@deverenozcan.com"].actions[0].value[0] == "fallback@example.com"
    )
    error_message = "eren.ozcan@ must keep being forwarded to the fallback address."
  }

  assert {
    condition = (
      cloudflare_email_routing_catch_all.all[0].matchers[0].type == "all" &&
      cloudflare_email_routing_catch_all.all[0].actions[0].type == "worker" &&
      cloudflare_email_routing_catch_all.all[0].actions[0].value[0] == "mail-inbound"
    )
    error_message = "route_all_mail must point the catch-all at the Worker."
  }
}
