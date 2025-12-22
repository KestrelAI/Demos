# Kestrel AI Demos

This repository contains demonstration infrastructure configurations for showcasing Kestrel AI's cloud incident response capabilities.

## Available Demos

### [VPC Peering Blackhole Demo](./vpc-peering-blackhole-demo/)

Demonstrates a common VPC peering misconfiguration where asymmetric routing causes network "blackholes" - traffic flows one way but responses cannot return.

### [MSK Broker Resource Constraint Demo](./msk-broker-constraint-demo/)

Demonstrates how undersized MSK brokers become resource-constrained under production load. Creates an MSK cluster with undersized brokers and generates high-volume traffic to trigger CPU and memory exhaustion.

## License

MIT

