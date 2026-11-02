import asyncio
from bleak import BleakScanner, BleakClient
from oku import QCY, SVC, CMD, NTF, frame
async def main():
    dev = await BleakScanner.find_device_by_filter(lambda d,a: QCY in a.manufacturer_data, timeout=15)
    async with BleakClient(dev, timeout=20) as c:
        s=c.services.get_service(SVC)
        await c.start_notify(s.get_characteristic(NTF), lambda _,d: print("<<", d.hex(" ")))
        print(">> ANC AÇ (iç mekan, seviye 2)")
        await c.write_gatt_char(s.get_characteristic(CMD), frame((0x17,[0x01,0x01,0x02])), response=False)
        await asyncio.sleep(6)
        print(">> NORMAL")
        await c.write_gatt_char(s.get_characteristic(CMD), frame((0x17,[0x02,0x00,0x00])), response=False)
        await asyncio.sleep(1.5)
asyncio.run(main())
