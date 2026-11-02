"""Salt okunur keşif: QCY BLE yayınlarını bulur, GATT servislerini listeler. Kulaklığa hiçbir şey yazmaz."""
import asyncio
from bleak import BleakScanner, BleakClient

QCY = 0x521C


async def main():
    found = {}

    def cb(dev, adv):
        md = adv.manufacturer_data.get(QCY)
        if md is not None or (adv.local_name and "QCY" in adv.local_name.upper()):
            found[dev.address] = (dev, adv)

    async with BleakScanner(cb):
        await asyncio.sleep(12)

    if not found:
        print("QCY BLE yayını bulunamadı.")
        return
    for addr, (dev, adv) in found.items():
        md = adv.manufacturer_data.get(QCY, b"")
        print(f"\n== {adv.local_name} | {addr} | RSSI {adv.rssi}")
        print("  manuf:", md.hex(" "))
        if len(md) >= 8:
            vid = md[0] << 8 | md[1]
            b = lambda x: f"{x & 0x7F}%{' (şarjda)' if x & 0x80 else ''}"
            print(f"  vendorId={vid}  sol={b(md[5])} sağ={b(md[6])} kutu={b(md[7])}")
    for addr, (dev, adv) in found.items():
        if QCY not in adv.manufacturer_data:
            continue
        print(f"\n-- GATT {addr}")
        try:
            async with BleakClient(dev, timeout=20) as c:
                for s in c.services:
                    print(" S", s.uuid)
                    for ch in s.characteristics:
                        print("    C", ch.uuid, ",".join(ch.properties))
        except Exception as e:
            print("  bağlanamadı:", repr(e))


asyncio.run(main())
