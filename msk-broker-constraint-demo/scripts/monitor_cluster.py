#!/usr/bin/env python3
"""
Kestrel MSK Partition Hotspot Demo - Cluster Monitor

This script monitors the MSK cluster for signs of partition imbalance:
- Partition message rates (identifies hotspots)
- Consumer group lag (identifies struggling consumers)
- Broker load distribution

Use this to visualize the problem before Kestrel detects and fixes it.
"""

import argparse
import json
import time
import subprocess
import sys
from datetime import datetime


def run_kafka_command(kafka_path, command, bootstrap_servers):
    """Run a Kafka CLI command and return output"""
    full_cmd = f"{kafka_path}/bin/{command} --bootstrap-server {bootstrap_servers}"
    try:
        result = subprocess.run(
            full_cmd.split(),
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.stdout, result.stderr
    except Exception as e:
        return None, str(e)


def get_topic_partitions(kafka_path, bootstrap_servers, topic):
    """Get partition info for a topic"""
    stdout, stderr = run_kafka_command(
        kafka_path,
        f"kafka-topics.sh --describe --topic {topic}",
        bootstrap_servers
    )
    
    if not stdout:
        return None
    
    partitions = []
    for line in stdout.strip().split('\n'):
        if 'Partition:' in line:
            parts = line.split('\t')
            partition_info = {}
            for part in parts:
                if ':' in part:
                    key, value = part.split(':', 1)
                    partition_info[key.strip()] = value.strip()
            partitions.append(partition_info)
    
    return partitions


def get_consumer_lag(kafka_path, bootstrap_servers, group_id):
    """Get consumer group lag"""
    stdout, stderr = run_kafka_command(
        kafka_path,
        f"kafka-consumer-groups.sh --describe --group {group_id}",
        bootstrap_servers
    )
    
    if not stdout or 'Error' in stdout:
        return None
    
    lag_info = []
    lines = stdout.strip().split('\n')
    headers = None
    
    for line in lines:
        if not line.strip():
            continue
        if 'TOPIC' in line and 'PARTITION' in line:
            headers = line.split()
            continue
        if headers and line.strip():
            values = line.split()
            if len(values) >= len(headers):
                row = dict(zip(headers, values))
                lag_info.append(row)
    
    return lag_info


def get_log_end_offsets(kafka_path, bootstrap_servers, topic):
    """Get log end offsets for all partitions"""
    stdout, stderr = run_kafka_command(
        kafka_path,
        f"kafka-run-class.sh kafka.tools.GetOffsetShell --topic {topic} --time -1",
        bootstrap_servers
    )
    
    if not stdout:
        return None
    
    offsets = {}
    for line in stdout.strip().split('\n'):
        if ':' in line:
            parts = line.split(':')
            if len(parts) >= 3:
                partition = int(parts[1])
                offset = int(parts[2])
                offsets[partition] = offset
    
    return offsets


def monitor_cluster(kafka_path, bootstrap_servers, topic, group_id, interval=10):
    """
    Continuously monitor the cluster for hotspots and lag.
    """
    print(f"MSK Cluster Monitor")
    print(f"=" * 60)
    print(f"Topic: {topic}")
    print(f"Consumer Group: {group_id}")
    print(f"Refresh Interval: {interval}s")
    print(f"=" * 60)
    print()
    
    prev_offsets = None
    
    try:
        while True:
            now = datetime.now().strftime('%H:%M:%S')
            print(f"\n[{now}] Checking cluster status...")
            print("-" * 60)
            
            # Get partition info
            partitions = get_topic_partitions(kafka_path, bootstrap_servers, topic)
            if partitions:
                print(f"\nTopic Partitions ({len(partitions)} total):")
                for p in partitions:
                    leader = p.get('Leader', 'N/A')
                    replicas = p.get('Replicas', 'N/A')
                    isr = p.get('Isr', 'N/A')
                    partition_num = p.get('Partition', 'N/A')
                    
                    # Check for ISR shrink
                    isr_warning = ""
                    if isr != replicas:
                        isr_warning = " ⚠️ ISR SHRINK!"
                    
                    print(f"  P{partition_num}: Leader={leader}, Replicas={replicas}, ISR={isr}{isr_warning}")
            
            # Get current offsets and calculate message rates
            curr_offsets = get_log_end_offsets(kafka_path, bootstrap_servers, topic)
            if curr_offsets:
                print(f"\nPartition Message Rates:")
                total_rate = 0
                rates = {}
                
                if prev_offsets:
                    for partition, offset in sorted(curr_offsets.items()):
                        prev = prev_offsets.get(partition, offset)
                        rate = (offset - prev) / interval
                        rates[partition] = rate
                        total_rate += rate
                    
                    # Identify hotspots (partitions with >30% of traffic)
                    if total_rate > 0:
                        for partition, rate in sorted(rates.items()):
                            pct = (rate / total_rate) * 100 if total_rate > 0 else 0
                            hotspot = " 🔥 HOTSPOT!" if pct > 30 else ""
                            bar = "█" * int(pct / 5)
                            print(f"  P{partition}: {rate:6.1f} msg/s ({pct:5.1f}%) {bar}{hotspot}")
                        print(f"  Total: {total_rate:.1f} msg/s")
                else:
                    print("  (Collecting baseline data...)")
                
                prev_offsets = curr_offsets
            
            # Get consumer lag
            lag_info = get_consumer_lag(kafka_path, bootstrap_servers, group_id)
            if lag_info:
                print(f"\nConsumer Group Lag ({group_id}):")
                total_lag = 0
                for row in lag_info:
                    partition = row.get('PARTITION', 'N/A')
                    lag = row.get('LAG', '0')
                    try:
                        lag_int = int(lag)
                        total_lag += lag_int
                        lag_warning = " ⚠️ HIGH LAG!" if lag_int > 1000 else ""
                        print(f"  P{partition}: {lag_int:,} messages behind{lag_warning}")
                    except:
                        print(f"  P{partition}: {lag}")
                print(f"  Total lag: {total_lag:,} messages")
            else:
                print(f"\nConsumer Group '{group_id}' not found or no lag data")
            
            print(f"\n(Next check in {interval}s, Ctrl+C to stop)")
            time.sleep(interval)
            
    except KeyboardInterrupt:
        print("\n\nMonitor stopped.")


def main():
    parser = argparse.ArgumentParser(description='MSK Cluster Monitor')
    parser.add_argument('--bootstrap-servers', '-b', required=True,
                        help='Kafka bootstrap servers')
    parser.add_argument('--topic', '-t', default='hotspot-demo',
                        help='Topic to monitor (default: hotspot-demo)')
    parser.add_argument('--group', '-g', default='hotspot-consumer',
                        help='Consumer group to monitor (default: hotspot-consumer)')
    parser.add_argument('--kafka-path', '-k', default='/opt/kafka',
                        help='Path to Kafka installation (default: /opt/kafka)')
    parser.add_argument('--interval', '-i', type=int, default=10,
                        help='Refresh interval in seconds (default: 10)')
    
    args = parser.parse_args()
    
    monitor_cluster(
        kafka_path=args.kafka_path,
        bootstrap_servers=args.bootstrap_servers,
        topic=args.topic,
        group_id=args.group,
        interval=args.interval
    )


if __name__ == '__main__':
    main()
