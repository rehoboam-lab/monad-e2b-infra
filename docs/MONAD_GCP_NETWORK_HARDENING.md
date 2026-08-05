# Monad GCP network hardening status and rollout

Status date: 2026-08-05. GCP project: `monad-code`. Region: `us-east4`.

This document records the read-only live audit behind the invited-beta network hardening and the
prerequisites for applying it. The changes described here are source changes only until a guarded,
reviewed Terraform plan is applied.

## Live audit

The audit used the authenticated `yasser@engram.org` gcloud account and printed no credential or
SSH-key value.

- All eight `e2b-orch-*` instances (three servers, two API nodes, two workers, and one build node)
  have private `10.150.0.0/20` addresses and no per-instance public address.
- `e2b-orch-internal-remote-connection-firewall-ingress` currently allows TCP 22/3389 from
  `0.0.0.0/0` at priority 900 and has logging disabled. The priority-1000 non-IAP deny therefore
  never sees those packets. This is the live defect fixed by this branch.
- Project common metadata contains a legacy `ssh-keys` entry and no `enable-oslogin` entry. None of
  the eight live fleet instances has an instance-level `enable-oslogin` value. The effective
  `constraints/compute.requireOsLogin` response did not report enforcement.
- The project IAM policy has no project-local `roles/compute.osLogin`,
  `roles/compute.osAdminLogin`, or `roles/iap.tunnelResourceAccessor` binding. Inherited IAM was not
  proven by this query and must not be assumed. The active operator account's OS Login profile
  returned no POSIX account and no OS Login SSH key.
- The live workload subnet is `10.150.0.0/20`; fleet nodes are `10.150.0.x`. The private Cloud SQL
  addresses are `10.26.7.3` and `10.26.7.6`. These destinations, metadata
  `169.254.169.254`, RFC1918, CGNAT, loopback, and IPv6 local ranges all fall within the
  Firecracker slot's existing predefined nftables deny set.
- The GCP environment does not set `ALLOW_SANDBOX_INTERNAL_CIDRS`; its effective value is the empty
  default. This branch makes any non-empty GCP value a Terraform validation error.

## Source invariants

- The `orch` administrative allow is exactly `35.235.240.0/20`, ports 22/3389, priority 900.
- The public-source administrative deny remains priority 1000. Both rules log decisions with
  `EXCLUDE_ALL_METADATA`.
- Server, API, worker/build, Loki, and ClickHouse instance templates set
  `enable-oslogin = "TRUE"`. The API template no longer ignores all metadata changes.
- `os_login_operator_access_confirmed` defaults to false. Its Terraform precondition prevents any
  workload plan until the reviewed inputs explicitly set it true.
- Guest private/control-plane denies run on the tap before host NAT and before tenant allow rules.
  The host's own metadata ADC path does not traverse that tap rule.
- `make -C iac/provider-gcp network-security-check` guards all of these source relationships and
  runs the root-free GCP control-plane CIDR test.

## Validation evidence

The local branch passed the following checks before handoff:

- Terraform 1.7.5 formatting and `validate` for both `iac/provider-gcp` and the Packer network
  configuration.
- The complete workload plan-assertion fixture suite, including quota, mutation-lease, release,
  cluster-readiness, template-manager, and worker-startup guards.
- `network-security-check`, including a real minimal Terraform plan that fails with the OS Login
  confirmation omitted and succeeds with explicit confirmation.
- The complete Linux `packages/orchestrator/pkg/sandbox/network` suite in a privileged container,
  including real network-namespace, iptables, and nftables tests.
- The complete Linux `packages/orchestrator/pkg/tcpfirewall` suite with its Docker-backed listener
  test, plus the shared sandbox-network package tests.
- The keyless-runtime guard suite, `shellcheck`, `actionlint`, and `git diff --check`.

## Apply prerequisites

Do not apply this branch merely because validation is green.

1. Choose the named operator group or principal. Grant the least-privilege project access needed
   for `roles/iap.tunnelResourceAccessor` and `roles/compute.osAdminLogin`; verify inherited access
   explicitly if inheritance is intentional.
2. Prove an IAP TCP tunnel and OS Login administrative SSH on a disposable instance built from an
   OS-Login-enabled candidate template. Do not use a production worker as the first proof.
3. Add `os_login_operator_access_confirmed = true` to the reviewed, non-secret workload inputs only
   after that evidence exists. The default false value is intentional.
4. Produce the normal provenance-bound saved Terraform plan. It must contain the two bounded
   firewall updates and the expected instance-template replacements, with no public access config
   and no unrelated resource destruction.
5. Follow the existing drain procedure before each worker/build replacement: halt placement,
   pause or snapshot workcells, prove durable upload, drain Nomad, and verify zero allocations.
   Roll server and API pools without losing quorum or load-balancer health.
6. After every replacement, prove IAP/OS Login access, service health, attached-service-account ADC,
   host metadata reachability, guest metadata/private-control-plane denial, public egress through
   Cloud NAT, and zero leaked workcells before proceeding.
7. Only after every fleet node is on an OS-Login-enabled template should the legacy project
   `ssh-keys` metadata be removed in a separate reviewed operation with a rollback principal
   already proven.

The repository does not grant operator IAM because the authoritative operator group is an external
ownership decision. Until that principal is named and the canary proof passes, the Terraform guard
must remain closed and this change must remain unapplied.
