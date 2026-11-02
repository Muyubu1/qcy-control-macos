"""Salt okunur: sürüm, pil ve mevcut ayarları sorgular (0xFE = 'şu anki değeri söyle')."""
import asyncio
from bleak import BleakScanner, BleakClient

QCY = 0x521C
SVC = "0000a001-0000-1000-8000-00805f9b34fb"
CMD = "00001001-0000-1000-8000-00805f9b34fb"
NTF = "00001002-0000-1000-8000-00805f9b34fb"
VER = "00000007-0000-1000-8000-00805f9b34fb"
BAT = "00000008-0000-1000-8000-00805f9b34fb"
ASK = {0x0C: "ANC modu", 0x17: "ANC sahne", 0x09: "Oyun modu", 0x16: "Ses dengesi",
       0x23: "LDAC", 0x10: "Uyku modu", 0x24: "Çift cihaz", 0x2F: "Pil", 0x30: "Sürüm", 0x14: "Oto kapanma"}


def frame(*blocks):
    body = b"".join(bytes([c, len(p)]) + bytes(p) for c, p in blocks)
    return bytes([0xFF, len(body)]) + body


async def main():
    dev = await BleakScanner.find_device_by_filter(lambda d, a: QCY in a.manufacturer_data, timeout=15)
    if not dev:
        print("bulunamadı"); return
    async with BleakClient(dev, timeout=20) as c:
        a001 = c.services.get_service(SVC)
        ch = lambda u: a001.get_characteristic(u)
        print("version raw:", (await c.read_gatt_char(ch(VER))).hex(" "))
        print("battery raw:", (await c.read_gatt_char(ch(BAT))).hex(" "))
        print("eq raw     :", (await c.read_gatt_char(ch("0000000b-0000-1000-8000-00805f9b34fb"))).hex(" "))
        print("keys raw   :", (await c.read_gatt_char(ch("0000000d-0000-1000-8000-00805f9b34fb"))).hex(" "))

        def on(_, data):
            print("<<", data.hex(" "))
        await c.start_notify(ch(NTF), on)
        for cid, name in ASK.items():
            print(f">> ask {name} (0x{cid:02X})")
            await c.write_gatt_char(ch(CMD), frame((0xFE, [cid])), response=False)
            await asyncio.sleep(0.6)
        await asyncio.sleep(1.5)


if __name__ == "__main__":
    asyncio.run(main())
