#!/usr/bin/env python3
"""Forward 127.0.0.1:LISTEN_PORT to HOST:PORT (podman-forward starts it)."""
import asyncio, sys

async def pipe(r, w):
    try:
        while True:
            d = await r.read(65536)
            if not d:
                break
            w.write(d)
            await w.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass

async def handle(cr, cw, host, port):
    try:
        sr, sw = await asyncio.open_connection(host, port)
    except OSError:
        cw.close()
        return
    await asyncio.gather(pipe(cr, sw), pipe(sr, cw))

async def main(lp, host, port):
    srv = await asyncio.start_server(lambda r, w: handle(r, w, host, port), "127.0.0.1", lp, reuse_address=True)
    async with srv:
        await srv.serve_forever()

asyncio.run(main(int(sys.argv[1]), sys.argv[2], int(sys.argv[3])))
