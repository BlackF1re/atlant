#!/usr/bin/env python3
"""Stop an Antminer S9 controller at the U-Boot prompt after a power cycle."""
import serial
import sys
import time

port = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
deadline = time.monotonic() + 300
ser = serial.Serial(port, 115200, timeout=0.15)
ser.reset_input_buffer()
try:
    while time.monotonic() < deadline:
        # Vendor U-Boot treats a literal space more reliably than CR in its
        # very short autoboot polling window.  Spaces are harmless at both
        # the U-Boot prompt and the Linux serial console.
        ser.write(b" ")
        ser.flush()
        data = ser.read(4096)
        if data:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            if b"=>" in data or b"antminer>" in data:
                break
        time.sleep(0.01)
finally:
    ser.close()
