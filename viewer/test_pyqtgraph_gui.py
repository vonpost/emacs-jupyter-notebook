"""Headless Qt regression checks for the V2 viewer shell."""

import json
import os
import subprocess
import sys
import unittest


class ViewerSmokeTest(unittest.TestCase):
    def test_import_is_side_effect_free(self):
        code = "import ejn_viewer; print('ok')"
        result = subprocess.run([sys.executable, "-c", code], capture_output=True,
                                text=True, check=True, timeout=15)
        self.assertEqual(result.stdout.strip(), "ok")

    def test_offscreen_paints_resizes_and_closes(self):
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen")
        result = subprocess.run([sys.executable, "-m", "ejn_viewer",
                                 "--smoke-test", "--offscreen"],
                                capture_output=True, text=True, env=env, check=True,
                                timeout=15)
        evidence = json.loads(result.stdout)
        self.assertTrue(evidence["painted"])
        self.assertTrue(evidence["closed"])
        self.assertTrue(evidence["painted_after_reopen"])
        self.assertFalse(evidence["timed_out"])
        self.assertEqual(evidence["resized_to"], [840, 520])

    def test_white_and_black_viewports_fail_paint_probe(self):
        code = '''
from PySide6 import QtWidgets, QtGui
from ejn_viewer.app import _nonblank
app = QtWidgets.QApplication([])
class Blank:
    def __init__(self, color): self.color = color
    def grab(self):
        p = QtGui.QPixmap(100, 100)
        p.fill(QtGui.QColor(self.color))
        return p
class Window: pass
w = Window()
for color in ('white', 'black'):
    w._graphics = Blank(color)
    assert not _nonblank(w)
'''
        subprocess.run([sys.executable, "-c", code], check=True, timeout=15,
                       env=dict(os.environ, QT_QPA_PLATFORM="offscreen"))


if __name__ == "__main__":
    unittest.main()
