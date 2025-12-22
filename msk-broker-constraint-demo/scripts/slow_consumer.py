#!/usr/bin/env python3
"""
Kestrel MSK Partition Hotspot Demo - Slow Consumer

This consumer intentionally processes messages slowly to demonstrate
consumer lag buildup when combined with the hotspot producer.

The consumer processes messages from specific partitions slower than others,
simulating a real-world scenario where:
- Some partition consumers are slower (resource constraints)
- Processing time varies by message type/customer
- A downstream dependency causes delays

The result: Consumer lag builds up, especially on hot partitions
"""

import argparse
import json
import time
import random
import sys
from datetime import datetime
from confluent_kafka import Consumer, KafkaError, KafkaException

# Partitions that will be processed slowly (simulating bottleneck)
SLOW_PARTITIONS = [0, 1]  # These often get hot keys due to hashing
SLOW_PROCESSING_TIME = 0.1  # 100ms per message on slow partitions
FAST_PROCESSING_TIME = 0.01  # 10ms per message on fast partitions


def process_message(msg, slow_mode=True):
    """
    Simulate message processing with variable latency.
    
    In slow_mode, partitions 0 and 1 are processed 10x slower,
    simulating a bottleneck on hot partitions.
    """
    partition = msg.partition()
    
    if slow_mode and partition in SLOW_PARTITIONS:
        time.sleep(SLOW_PROCESSING_TIME)
    else:
        time.sleep(FAST_PROCESSING_TIME)
    
    return partition


def run_consumer(bootstrap_servers, topic, group_id, slow_mode=True, max_messages=None):
    """
    Run the consumer with optional slow processing on hot partitions.
    
    Args:
        bootstrap_servers: Kafka bootstrap servers
        topic: Topic to consume from
        group_id: Consumer group ID
        slow_mode: If True, process hot partitions slowly
        max_messages: Stop after this many messages (None for infinite)
    """
    conf = {
        'bootstrap.servers': bootstrap_servers,
        'group.id': group_id,
        'auto.offset.reset': 'earliest',
        'enable.auto.commit': True,
        'auto.commit.interval.ms': 5000,
        'session.timeout.ms': 30000,
        'max.poll.interval.ms': 300000,
    }
    
    consumer = Consumer(conf)
    consumer.subscribe([topic])
    
    mode = "SLOW (bottleneck simulation)" if slow_mode else "FAST"
    
    print(f"Starting {mode} consumer")
    print(f"  Bootstrap servers: {bootstrap_servers}")
    print(f"  Topic: {topic}")
    print(f"  Group ID: {group_id}")
    if slow_mode:
        print(f"  Slow partitions: {SLOW_PARTITIONS}")
    print()
    
    message_count = 0
    partition_counts = {}
    partition_lag_time = {}
    start_time = time.time()
    
    try:
        while True:
            msg = consumer.poll(timeout=1.0)
            
            if msg is None:
                continue
            
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    print(f"Reached end of partition {msg.partition()}")
                else:
                    raise KafkaException(msg.error())
                continue
            
            # Process the message
            partition = process_message(msg, slow_mode)
            message_count += 1
            
            # Track partition distribution
            partition_counts[partition] = partition_counts.get(partition, 0) + 1
            
            # Calculate message age (lag indicator)
            try:
                payload = json.loads(msg.value().decode('utf-8'))
                msg_time = datetime.fromisoformat(payload['timestamp'])
                age_seconds = (datetime.utcnow() - msg_time).total_seconds()
                
                if partition not in partition_lag_time:
                    partition_lag_time[partition] = []
                partition_lag_time[partition].append(age_seconds)
                
                # Keep only recent samples
                if len(partition_lag_time[partition]) > 100:
                    partition_lag_time[partition] = partition_lag_time[partition][-100:]
            except:
                pass
            
            # Print progress every 100 messages
            if message_count % 100 == 0:
                elapsed = time.time() - start_time
                rate = message_count / elapsed if elapsed > 0 else 0
                print(f"[{elapsed:.0f}s] Consumed {message_count} messages ({rate:.1f} msg/sec)")
                
                # Show partition distribution
                print(f"  Partition distribution: {dict(sorted(partition_counts.items()))}")
                
                # Show average lag per partition
                if partition_lag_time:
                    avg_lags = {p: sum(times)/len(times) 
                               for p, times in partition_lag_time.items() if times}
                    print(f"  Avg message age (lag): {', '.join(f'P{p}:{lag:.1f}s' for p, lag in sorted(avg_lags.items()))}")
            
            if max_messages and message_count >= max_messages:
                print(f"\nReached max messages: {max_messages}")
                break
                
    except KeyboardInterrupt:
        print("\nInterrupted by user")
    finally:
        consumer.close()
        
        elapsed = time.time() - start_time
        print(f"\nConsumer finished:")
        print(f"  Total messages: {message_count}")
        print(f"  Duration: {elapsed:.1f} seconds")
        if elapsed > 0:
            print(f"  Actual rate: {message_count/elapsed:.1f} msg/sec")
        
        print(f"\nPartition distribution:")
        for partition, count in sorted(partition_counts.items()):
            pct = (count / message_count) * 100 if message_count > 0 else 0
            slow_indicator = " (SLOW)" if slow_mode and partition in SLOW_PARTITIONS else ""
            print(f"  Partition {partition}: {count} ({pct:.1f}%){slow_indicator}")


def main():
    parser = argparse.ArgumentParser(description='MSK Slow Consumer (Lag Simulator)')
    parser.add_argument('--bootstrap-servers', '-b', required=True,
                        help='Kafka bootstrap servers')
    parser.add_argument('--topic', '-t', default='hotspot-demo',
                        help='Topic to consume from (default: hotspot-demo)')
    parser.add_argument('--group', '-g', default='hotspot-consumer',
                        help='Consumer group ID (default: hotspot-consumer)')
    parser.add_argument('--fast', action='store_true',
                        help='Run in fast mode (no artificial delays)')
    parser.add_argument('--max-messages', '-m', type=int,
                        help='Stop after this many messages')
    
    args = parser.parse_args()
    
    run_consumer(
        bootstrap_servers=args.bootstrap_servers,
        topic=args.topic,
        group_id=args.group,
        slow_mode=not args.fast,
        max_messages=args.max_messages
    )


if __name__ == '__main__':
    main()
