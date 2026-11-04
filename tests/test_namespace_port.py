"""Run with `python tests/test_namespace_port.py`"""

import threading

import rpyc

from qudi.core.servers import _ServerRunnable


def test_port_zero_reports_bound_port():
    runnable = _ServerRunnable(service=rpyc.Service, host='localhost', port=0)
    threading.Thread(target=runnable.run, daemon=True).start()
    assert runnable.bound.wait(timeout=5)
    assert runnable.port > 0, runnable.port
    rpyc.connect('localhost', runnable.port).close()
    runnable.stop()


if __name__ == '__main__':
    test_port_zero_reports_bound_port()
