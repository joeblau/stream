import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ffmpeg_receiver as receiver


class ReceiverSelectionTests(unittest.TestCase):
    def reports(self):
        return {
            "protocols": "Input:\n  rtmp\n  tcp\n  srt\nOutput:\n  rtmp\n  srt\n",
            "rtmp": "  -listen <int> .D......... Listen for incoming connections\n",
            "decoders": " VFS..D h264 H.264\n A....D aac AAC\n",
            "encoders": " V..... wrapped_avframe passthrough\n A....D pcm_s16le PCM\n",
            "demuxers": " D flv FLV\n D mov,mp4,m4a,3gp,3g2,mj2 QuickTime\n D mpegts MPEG-TS\n",
            "muxers": " E mp4 MP4\n E null null\n",
        }

    def test_receive_direction_and_optional_srt(self):
        reports = self.reports()
        self.assertEqual(receiver.missing_capabilities(reports, True), [])
        reports["protocols"] = "Input:\n rtmp\n tcp\nOutput:\n rtmp\n srt\n"
        self.assertEqual(receiver.missing_capabilities(reports), [])
        self.assertIn("SRT input (shared publishing fixture)", receiver.missing_capabilities(reports, True))
        reports["protocols"] = "Input:\n file\nOutput:\n rtmp\n"
        self.assertIn("RTMP input", receiver.missing_capabilities(reports))

    def test_decoders_muxing_and_listen_are_required(self):
        reports = self.reports()
        reports["rtmp"] = "Unknown protocol rtmp"
        reports["decoders"] = " V..... other Other\n"
        reports["muxers"] = " E matroska Matroska\n"
        self.assertEqual(set(receiver.missing_capabilities(reports)), {
            "RTMP -listen input option", "H.264 decoder", "AAC decoder", "MP4 output muxer", "null output muxer"})

    def test_override_is_exclusive_even_when_invalid(self):
        for invalid in ("", "/no-such-stream-ffmpeg", tempfile.gettempdir()):
            with self.subTest(invalid=invalid), patch.object(receiver, "validate") as validate:
                with self.assertRaises(receiver.ReceiverError):
                    receiver.select({"STREAM_FFMPEG_BIN": invalid, "PATH": os.environ["PATH"]})
                validate.assert_not_called()

    def test_path_can_select_any_architecture_prefix_including_spaces(self):
        with tempfile.TemporaryDirectory(prefix="receiver path ") as folder:
            binary = Path(folder) / "ffmpeg"
            binary.touch(); binary.chmod(0o755)
            with patch.object(receiver, "validate") as validate:
                self.assertEqual(receiver.select({"PATH": folder}), binary.resolve())
                validate.assert_called_once_with(binary.resolve(), False)


if __name__ == "__main__":
    unittest.main()
