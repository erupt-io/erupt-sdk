import json
import unittest
from pathlib import Path

from erupt import _signature

VECTORS = json.loads((Path(__file__).resolve().parents[2] / "conformance" / "signature-vectors.json").read_text("utf-8"))


class SignatureTest(unittest.TestCase):

    def test_java_vectors(self):
        for v in VECTORS["vectors"]:
            with self.subTest(v["case"]):
                body = None if v["body"] is None else v["body"].encode()
                self.assertEqual(v["signature"], _signature.sign(VECTORS["accessToken"], v["method"], v["pathAndQuery"],
                                                                 v["timestamp"], v["enforced"], v["user"], body))
                self.assertTrue(_signature.verify(VECTORS["accessToken"], v["method"], v["pathAndQuery"], str(v["timestamp"]),
                                                  v["enforced"], v["user"], body, v["signature"], v["timestamp"] + 300))
                self.assertFalse(_signature.verify(VECTORS["accessToken"], v["method"], v["pathAndQuery"], str(v["timestamp"]),
                                                   v["enforced"], v["user"], body, v["signature"], v["timestamp"] + 301))


if __name__ == "__main__":
    unittest.main()
