#!/usr/bin/env python3
"""
MSK Stress Test - Proven working configuration
"""

import argparse
import random
import time
import sys
import string
from multiprocessing import Process, Value
from ctypes import c_long

try:
    from confluent_kafka import Producer
except ImportError:
    print("ERROR: confluent-kafka required. Install: pip3 install confluent-kafka")
    sys.exit(1)


def create_message(size_kb=10):
    """Create message payload"""
    return ''.join(random.choices(string.ascii_letters + string.digits, k=size_kb * 1024))


def producer_worker(proc_id, bootstrap_servers, topic, duration, msg_size_kb, counter):
    """Producer that sends messages as fast as possible"""
    conf = {
        'bootstrap.servers': bootstrap_servers,
        'client.id': f'stress-{proc_id}',
        'acks': 'all',
        'linger.ms': 0,
        'batch.size': 1048576,  # 1MB batches
        'compression.type': 'none',
        'queue.buffering.max.messages': 100000,
        'queue.buffering.max.kbytes': 1048576,
        'message.max.bytes': 1048576,
    }
    
    producer = Producer(conf)
    start = time.time()
    local_count = 0
    
    # Pre-generate messages
    messages = [create_message(msg_size_kb) for _ in range(5)]
    
    print(f"[P{proc_id:02d}] Started ({msg_size_kb}KB messages)", flush=True)
    
    try:
        while time.time() - start < duration:
            key = f"key-{random.randint(1, 100)}"
            value = random.choice(messages)
            
            try:
                producer.produce(topic, key=key.encode(), value=value.encode())
                local_count += 1
                counter.value += 1
            except BufferError:
                producer.poll(0.1)
                continue
            
            if local_count % 100 == 0:
                producer.poll(0)
                
    except Exception as e:
        print(f"[P{proc_id:02d}] Error: {e}", flush=True)
    finally:
        producer.flush(timeout=30)
    
    elapsed = time.time() - start
    rate = local_count / elapsed if elapsed > 0 else 0
    mb_sec = (rate * msg_size_kb) / 1024
    print(f"[P{proc_id:02d}] Done: {local_count:,} msgs ({rate:.0f}/sec, {mb_sec:.1f} MB/sec)", flush=True)


def main():
    parser = argparse.ArgumentParser(description='MSK Stress Test')
    parser.add_argument('-b', '--bootstrap-servers', required=True)
    parser.add_argument('-t', '--topic', default='stress-test')
    parser.add_argument('-d', '--duration', type=int, default=300)
    parser.add_argument('-p', '--processes', type=int, default=16)
    parser.add_argument('-s', '--size', type=int, default=10, help='Message size in KB')
    
    args = parser.parse_args()
    
    print("=" * 70)
    print("MSK STRESS TEST")
    print("=" * 70)
    print(f"Bootstrap: {args.bootstrap_servers[:60]}...")
    print(f"Topic: {args.topic}")
    print(f"Duration: {args.duration}s")
    print(f"Processes: {args.processes}")
    print(f"Message size: {args.size} KB")
    print("=" * 70)
    print(flush=True)
    
    total_counter = Value(c_long, 0)
    start = time.time()
    
    processes = []
    for i in range(args.processes):
        p = Process(target=producer_worker, 
                   args=(i, args.bootstrap_servers, args.topic, args.duration, args.size, total_counter))
        p.start()
        processes.append(p)
    
    print(f"\n[MAIN] {args.processes} producers running\n", flush=True)
    
    try:
        while any(p.is_alive() for p in processes):
            time.sleep(10)
            elapsed = time.time() - start
            count = total_counter.value
            rate = count / elapsed if elapsed > 0 else 0
            mb_sec = (rate * args.size) / 1024
            print(f"[{elapsed:>5.0f}s] {count:>8,} msgs | {rate:>6.0f}/sec | {mb_sec:>6.1f} MB/sec", flush=True)
    except KeyboardInterrupt:
        for p in processes:
            p.terminate()
    
    for p in processes:
        p.join(timeout=5)
    
    elapsed = time.time() - start
    total = total_counter.value
    mb_total = (total * args.size) / 1024
    
    print()
    print("=" * 70)
    print(f"TOTAL: {total:,} messages ({mb_total:,.0f} MB) in {elapsed:.1f}s")
    print("=" * 70)


if __name__ == '__main__':
    main()

