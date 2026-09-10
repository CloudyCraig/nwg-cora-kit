# NWG demo — London build (Craig's acct 445740536021, eu-west-1)

All resources tagged `splunk-demo=NWG-demo` (+ `splunkit_environment_type=non-prd`,
`splunkit_data_classification=public` on EC2, required by the account SCP).

## Networking (vpc-4c85aa29) — the subnet gotcha
- **NAT-backed private subnets** (EKS nodes): subnet-0ef87dd4a95f404c4 (1a), subnet-0585cb2008ed56560 (1b)
  → route table rtb-04f8c2e92d3d30c5e, `0.0.0.0/0 → nat-0c51aa9093cb8ff9f`
- **Public IGW subnet** (Splunk box): subnet-0afe9490c12de9517 (also subnet-08b4e82886e8e0bec)
  → route table rtb-0c2b9533f95acbbd4, `0.0.0.0/0 → igw-f84e2c9d`
- **DEAD default subnets** (do NOT use): subnet-90decef5 / ca2e16bd / fe2c7ca7 — fall through to the
  main route table rtb-63716606 which has NO gateway route. Instances there boot but have no
  inbound/outbound path. (First nodegroup + first Splunk box failed here.)

## EKS
- Cluster: **nwg-demo** (1.30), control-plane ENIs in default subnets (fine — in-VPC only),
  public API endpoint. Node group **ng-nwg**: 2× t3.xlarge in the NAT subnets, privateNetworking.

## Splunk box
- Instance **i-03801a7c806a4ac14**, m6i.4xlarge, AMI ami-0ac9c92adc4fce69d (London clone)
- Public IP **18.201.12.210** (https://nwg.crgpov.com), subnet-0afe9490c12de9517
- SG **sg-04f34b193f6df8f89** (nwg-demo-splunk-sg): 22/8000/8089/443/80 from Craig's IP; 8088 from Craig + VPC CIDR
- Key: craig_aws_ireland

## ECR (eu-west-1)
- natwest-payments-{service, ledger-service-java, chaos-controller, rum-user-simulator,
  traffic-generator, web-frontend} — tags copied 1:1 from Marc's eu-west-2 repos.

## Kafka producer startup-race — auto-handled (2026-08-04)
payment-initiation-service (the only kafka producer) has a `wait-for-kafka` initContainer
(busybox nc kafka:9092) so it can't start before kafka is ready — else its producer inits dead and
the back-office chain (settlement/reconciliation/reporting) stays isolated in APM. Patch:
ops/london-build/payment-initiation-wait-for-kafka.patch.json (applied to the live deploy; re-apply on rebuild).
