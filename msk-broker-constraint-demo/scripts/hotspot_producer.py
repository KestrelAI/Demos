#!/usr/bin/env python3
"""
Kestrel MSK Partition Hotspot Demo - Skewed Producer

This producer intentionally creates partition hotspots by sending most messages
to a small subset of partitions. This simulates a real-world scenario where:
- A poorly designed key distribution causes partition imbalance
- A few "hot" customers/tenants dominate traffic
- A bug causes messages to cluster on specific partitions

The result: Broker imbalance, ISR shrink events, consumer lag buildup
"""

import argparse
import json
import random
import time
import sys
from datetime import datetime
from confluent_kafka import Producer

# Skewed key distribution: 80% of messages go to 2 "hot" keys
HOT_KEYS = ["hot-customer-1", "hot-customer-2"]
COLD_KEYS = [f"customer-{i}" for i in range(3, 100)]

# Weight distribution: hot keys get 80% of traffic
HOT_KEY_WEIGHT = 0.8


def get_skewed_key():
    """Return a message key with skewed distribution (creates hotspots)"""
    if random.random() < HOT_KEY_WEIGHT:
        return random.choice(HOT_KEYS)
    else:
        return random.choice(COLD_KEYS)


def get_balanced_key():
    """Return a message key with balanced distribution (no hotspots)"""
    all_keys = HOT_KEYS + COLD_KEYS
    return random.choice(all_keys)


def delivery_callback(err, msg):
    """Callback for message delivery confirmation"""
    if err:
        print(f"ERROR: Message delivery failed: {err}")
    else:
        # Uncomment for verbose output:
        # print(f"Delivered to {msg.topic()}[{msg.partition()}] @ offset {msg.offset()}")
        pass


def create_message():
    """Create a sample message payload"""
    return json.dumps({
        "timestamp": datetime.utcnow().isoformat(),
        "event_type": "transaction",
        "amount": round(random.uniform(10, 1000), 2),
        "currency": "USD",
        "metadata": {
            "source": "hotspot-demo",
            "version": "1.0"
        }
    })


def run_producer(bootstrap_servers, topic, skewed=True, rate=100, duration=300):
    """
    Run the producer with either skewed or balanced key distribution.
    
    Args:
        bootstrap_servers: Kafka bootstrap servers
        topic: Topic to produce to
        skewed: If True, use skewed key distribution (creates hotspots)
        rate: Messages per second
        duration: How long to run (seconds)
    """
    conf = {
        'bootstrap.servers': bootstrap_servers,
        'client.id': 'hotspot-producer',
        'acks': 'all',  # Wait for all replicas
        'linger.ms': 5,
        'batch.size': 16384,
    }
    
    producer = Producer(conf)
    
    key_func = get_skewed_key if skewed else get_balanced_key
    mode = "SKEWED (hotspot)" if skewed else "BALANCED"
    
    print(f"Starting {mode} producer")
    print(f"  Bootstrap servers: {bootstrap_servers}")
    print(f"  Topic: {topic}")
    print(f"  Rate: {rate} msg/sec")
    print(f"  Duration: {duration} seconds")
    print()
    
    start_time = time.time()
    message_count = 0
    interval = 1.0 / rate
    
    partition_counts = {}
    
    try:
        while time.time() - start_time < duration:
            key = key_func()
            value = create_message()
            
            producer.produce(
                topic,
                key=key.encode('utf-8'),
                value=value.encode('utf-8'),
                callback=delivery_callback
            )
            
            message_count += 1
            
            # Track partition distribution (approximate via key)
            partition_counts[key] = partition_counts.get(key, 0) + 1
            
            # Print progress every 10 seconds
            elapsed = time.time() - start_time
            if message_count % (rate * 10) == 0:
                print(f"[{elapsed:.0f}s] Sent {message_count} messages...")
                
                # Show top keys
                top_keys = sorted(partition_counts.items(), key=lambda x: -x[1])[:5]
                print(f"  Top keys: {[(k, c) for k, c in top_keys]}")
            
            producer.poll(0)
            time.sleep(interval)
            
    except KeyboardInterrupt:
        print("\nInterrupted by user")
    finally:
        print(f"\nFlushing remaining messages...")
        producer.flush()
        
        elapsed = time.time() - start_time
        print(f"\nProducer finished:")
        print(f"  Total messages: {message_count}")
        print(f"  Duration: {elapsed:.1f} seconds")
        print(f"  Actual rate: {message_count/elapsed:.1f} msg/sec")
        
        # Show final key distribution
        print(f"\nKey distribution (top 10):")
        top_keys = sorted(partition_counts.items(), key=lambda x: -x[1])[:10]
        total = sum(partition_counts.values())
        for key, count in top_keys:
            pct = (count / total) * 100
            print(f"  {key}: {count} ({pct:.1f}%)")


def main():
    parser = argparse.ArgumentParser(description='MSK Partition Hotspot Producer')
    parser.add_argument('--bootstrap-servers', '-b', required=True,
                        help='Kafka bootstrap servers')
    parser.add_argument('--topic', '-t', default='hotspot-demo',
                        help='Topic to produce to (default: hotspot-demo)')
    parser.add_argument('--balanced', action='store_true',
                        help='Use balanced key distribution (no hotspots)')
    parser.add_argument('--rate', '-r', type=int, default=100,
                        help='Messages per second (default: 100)')
    parser.add_argument('--duration', '-d', type=int, default=300,
                        help='Duration in seconds (default: 300)')
    
    args = parser.parse_args()
    
    run_producer(
        bootstrap_servers=args.bootstrap_servers,
        topic=args.topic,
        skewed=not args.balanced,
        rate=args.rate,
        duration=args.duration
    )


if __name__ == '__main__':
    main()
