# NI PCI-6024E validation with Comedi

This document records the validated Linux/Comedi setup for an NI PCI-6024E connected to an NI CB-68LP terminal block. The card may be installed through an ASM1083/ASM1085 PCIe-to-PCI bridge.

## Validated hardware

- DAQ: National Instruments PCI-6024E
- Terminal block: NI CB-68LP
- Connector: 68-pin cable
- Linux driver: `ni_pcimio`
- Comedi device: `/dev/comedi0`
- Optional bridge: ASMedia ASM1083/ASM1085 PCIe-to-PCI

The CB-68LP is a passive one-to-one breakout. Terminal number `N` on the CB-68LP corresponds to pin `N` on the PCI-6024E connector.

## Authoritative references

- [NI 6023E/6024E/6025E User Manual](https://download.ni.com/support/manuals/322072c.pdf), Appendix B, page B-3, Figure B-1: **68-Pin E Series Connector Pin Assignments**
- [NI: Mapping CB-68LP/CB-68LPR Connector Block Pinout to NI DAQ Board](https://knowledge.ni.com/KnowledgeArticleDetails?id=kA00Z0000019MtySAE&l=en-US)

## Relevant connector pinout

| Function | CB-68LP terminal |
|---|---:|
| AI0 / ACH0 | 68 |
| AI1 / ACH1 | 33 |
| AI8 / ACH8 | 34 |
| AI9 / ACH9 | 66 |
| AO0 / DAC0OUT | 22 |
| AO1 / DAC1OUT | 21 |
| AIGND | 67, 64, 59, 56, 32, 29, 27, 24 |
| AOGND | 54, 55 |
| DIO0 | 52 |
| DIO1 | 17 |
| DIO2 | 49 |
| DIO3 | 47 |
| DIO4 | 19 |
| DIO5 | 51 |
| DIO6 | 16 |
| DIO7 | 48 |
| +5 V | 8, 14 |
| DGND | 53, 50, 44, 39, 36, 35, 18, 15, 13, 12, 9, 7, 4 |

For differential inputs, AI0 uses ACH0/ACH8 (pins 68/34), while AI1 uses ACH1/ACH9 (pins 33/66).

## Inspect the device

```bash
comedi_board_info /dev/comedi0
```

Expected PCI-6024E subdevices include:

| Subdevice | Type | Channels | Range |
|---:|---|---:|---|
| 0 | Analog input | 16 | ±10 V, ±5 V, ±0.5 V, ±0.05 V |
| 1 | Analog output | 2 | ±10 V |
| 2 | Digital I/O | 8 | 0–5 V |

AI and AO use 12-bit samples with `maxdata=4095`.

## Analog AO0-to-AI0 loopback

For a ground-referenced test, install these jumpers:

```text
22 (AO0 / DAC0OUT)  -> 68 (AI0 / ACH0)
55 (AOGND)          -> 67 (AIGND)
```

Run the diagnostic from the RTSyn workspace root:

```bash
./build/linux/x86_64/release/comedi-loopback /dev/comedi0 5 0 0 ground
./build/linux/x86_64/release/comedi-loopback /dev/comedi0 0 0 0 ground
./build/linux/x86_64/release/comedi-loopback /dev/comedi0 -5 0 0 ground
./build/linux/x86_64/release/comedi-loopback /dev/comedi0 0 0 0 ground
```

Expected readings are approximately `+5 V`, `0 V`, `-5 V`, and `0 V`. One ADC count on the ±10 V range is approximately 4.884 mV.

A validated calibrated run produced:

| AO command | AI0 raw | Converted AI0 |
|---:|---:|---:|
| +5 V | 3071 | +4.998779 V |
| 0 V | 2048 | +0.002442 V |
| -5 V | 1024 | -4.998779 V |

Readings from the other AI channels should be ignored unless those channels are wired. Unconnected analog inputs float and can show arbitrary values or crosstalk.

## Direct analog-output test

To isolate AO0 from AI0, remove the loopback jumper and use a multimeter:

```text
Red probe:   terminal 22 (AO0)
Black probe: terminal 55 (AOGND)
```

Run the same `+5`, `0`, and `-5` commands. The meter must follow the commanded voltage. A successful write reported by Comedi does not by itself prove that the physical DAC output changed.

For AO1, use terminal 21 relative to terminal 55.

## Calibration

To freshly calibrate AI0 on the ±10 V ground-referenced range:

```bash
sudo comedi_calibrate \
  --reset \
  --calibrate \
  --results \
  --verbose \
  --file /dev/comedi0 \
  --subdevice 0 \
  --channel 0 \
  --range 0 \
  --aref 0
```

Test immediately after calibration. Do not unload `ni_pcimio` between calibration and testing because reloading the driver can discard the applied calibration state.

## Digital loopback

Install this jumper:

```text
52 (DIO0) -> 17 (DIO1)
```

Run:

```bash
sudo ./build/linux/x86_64/release/comedi-digital-loopback /dev/comedi0 0 1
```

Expected result:

```text
wrote DIO0=0, read DIO1=0: PASS
wrote DIO0=1, read DIO1=1: PASS
```

If writing low still reads high, DIO1 is probably floating. Verify the jumper and cable conductor with a continuity tester.

## Cable failure symptoms

A defective 68-pin cable previously caused all analog inputs to return raw zero and prevented the analog outputs from following commands. After replacing the cable:

- AO0 followed `+5 V`, `0 V`, and `-5 V` on a multimeter.
- AI0 tracked AO0 correctly after calibration.
- The PCIe-to-PCI adapter continued operating normally.

Therefore, verify the cable and individual conductors before blaming Comedi, PREEMPT_RT, or the PCIe-to-PCI bridge.

Useful checks include:

1. Measure terminal 14 relative to terminal 13; it should be close to +5 V.
2. Measure AO directly with a multimeter before testing AI.
3. Test digital continuity with the DIO loopback.
4. Ignore readings from unwired analog inputs.
5. Use the PCI-6024E manual's pinout rather than a generic 68-pin DAQ pinout.
