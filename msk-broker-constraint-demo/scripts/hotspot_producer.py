#!/usr/bin/env python3
"""
Kestrel MSK Broker Resource Constraint Demo - High-Volume Producer

This producer generates high-volume traffic to stress undersized Kafka brokers.
It uses uniform key distribution across partitions to evenly load all brokers,
which exposes resource constraints (CPU/memory) on undersized t3.small instances.

The result: High broker CPU, elevated memory usage, potential consumer lag
"""

import argparse
import json
import random
import time
import sys
from datetime import datetime
from confluent_kafka import Producer

# Use many keys for even distribution across partitions
ALL_KEYS = [f"customer-{i}" for i in range(1, 100)]


def get_uniform_key():
    """Return a message key with uniform distribution (even load across brokers)"""
    return random.choice(ALL_KEYS)


def delivery_callback(err, msg):
    """Callback for message delivery confirmation"""
    if err:
        print(f"ERROR: Message delivery failed: {err}")


def create_message():
    """Create a sample message payload"""
    return json.dumps({
        "timestamp": datetime.utcnow().isoformat(),
        "event_type": "transaction",
        "amount": round(random.uniform(10, 1000), 2),
        "currency": "USD",
        "metadata": {
            "source": "stress-demo",
            "version": "1.0"
        }
    })


def run_producer(bootstrap_servers, topic, rate=500, duration=600):
    """
    Run the high-volume producer to stress broker resources.
    
    Args:
        bootstrap_servers: Kafka bootstrap servers
        topic: Topic to produce to
        rate: Messages per second (default 500 to stress t3.small brokers)
        duration: How long to run (seconds)
    """
    conf = {
        'bootstrap.servers': bootstrap_servers,
        'client.id': 'stress-producer',
        'acks': 'all',  # Wait for all replicas
        'linger.ms': 5,
        'batch.size': 16384,
    }
    
    producer = Producer(conf)
    
    print(f"Starting high-volume producer (broker stress test)")
    print(f"  Bootstrap servers: {bootstrap_servers}")
    print(f"  Topic: {topic}")
    print(f"  Rate: {rate} msg/sec")
    print(f"  Duration: {duration} seconds")
    print(f"  Key distribution: UNIFORM (even load across all brokers)")
    print()
    
    start_time = time.time()
    message_count = 0
    interval = 1.0 / rate
    
    try:
        while time.time() - start_time < duration:
            key = get_uniform_key()
            value = create_message()
            
            producer.produce(
                topic,
                key=key.encode('utf-8'),
                value=value.encode('utf-8'),
                callback=delivery_callback
            )
            
            message_count += 1
            
            # Print progress every 10 seconds
            elapsed = time.time() - start_time
            if message_count % (rate * 10) == 0:
                actual_rate = message_count / elapsed if elapsed > 0 else 0
                print(f"[{elapsed:.0f}s] Sent {message_count} messages ({actual_rate:.0f} msg/sec)")
            
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


def main():
    parser = argparse.ArgumentParser(description='MSK Broker Stress Producer')
    parser.add_argument('--bootstrap-servers', '-b', required=True,
                        help='Kafka bootstrap servers')
    parser.add_argument('--topic', '-t', default='stress-demo',
                        help='Topic to produce to (default: stress-demo)')
    parser.add_argument('--rate', '-r', type=int, default=500,
                        help='Messages per second (default: 500)')
    parser.add_argument('--duration', '-d', type=int, default=600,
                        help='Duration in seconds (default: 600)')
    
    args = parser.parse_args()
    
    run_producer(
        bootstrap_servers=args.bootstrap_servers,
        topic=args.topic,
        rate=args.rate,
        duration=args.duration
    )


if __name__ == '__main__':
    main()
