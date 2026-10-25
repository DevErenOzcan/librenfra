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

variables {
  cloudflare_api_token = "not-used-by-the-mock"
  fallback_address     = "fallback@example.com"
}

# By default nothing changes where mail goes.
run "leaves_email_routing_alone_by_default" {
  command = plan

  assert {
    condition     = length(cloudflare_email_routing_rule.test) == 0 && length(cloudflare_email_routing_catch_all.all) == 0
    error_message = "Without test_address or route_all_mail, Email Routing must not be touched."
  }

  assert {
    condition = (
      cloudflare_zero_trust_tunnel_cloudflared_config.mail.config.ingress[0].hostname == "mx-in.deverenozcan.com" &&
      cloudflare_zero_trust_tunnel_cloudflared_config.mail.config.ingress[0].service == "http://127.0.0.1:8025" &&
      cloudflare_zero_trust_tunnel_cloudflared_config.mail.config.ingress[1].service == "http_status:404"
    )
    error_message = "The tunnel must send mx-in to the receiver on 127.0.0.1:8025, and nothing else anywhere."
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
    test_address = "test@deverenozcan.com"
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

run "routes_every_address_when_switched_over" {
  command = plan

  variables {
    route_all_mail = true
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
