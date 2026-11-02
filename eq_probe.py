import asyncio
from bleak import BleakScanner, BleakClient
from oku import QCY, SVC
EQ="0000000b-0000-1000-8000-00805f9b34fb"
async def main():
    dev = await BleakScanner.find_device_by_filter(lambda d,a: QCY in a.manufacturer_data, timeout=15)
    async with BleakClient(dev, timeout=20) as c:
        ch=c.services.get_service(SVC).get_characteristic(EQ)
        print("önce :", (await c.read_gatt_char(ch)).hex(" "))
        await c.write_gatt_char(ch, bytes([0x03]+[0]*10), response=False); await asyncio.sleep(1)
        print("idx3 :", (await c.read_gatt_char(ch)).hex(" "))
        await c.write_gatt_char(ch, bytes([0x01,6,5,3,0,0,0,0,0,0,0]), response=False); await asyncio.sleep(1)
        print("özel :", (await c.read_gatt_char(ch)).hex(" "))
        await c.write_gatt_char(ch, bytes([0x01]+[0]*10), response=False); await asyncio.sleep(1)
        print("geri :", (await c.read_gatt_char(ch)).hex(" "))
asyncio.run(main())
