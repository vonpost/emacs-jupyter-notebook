import unittest
from unittest import mock

from ejn_helper import thumbnail_worker


class ThumbnailWorkerLimitTests(unittest.TestCase):
    def test_linux_x86_64_uses_the_tighter_address_space_limit(self):
        with mock.patch.object(thumbnail_worker.sys, "platform", "linux"), mock.patch.object(
            thumbnail_worker.platform, "machine", return_value="x86_64"
        ), mock.patch.object(thumbnail_worker, "_set_limit") as set_limit:
            thumbnail_worker.apply_limits()

        self.assertEqual(
            set_limit.call_args_list,
            [
                mock.call("RLIMIT_CPU", 3),
                mock.call("RLIMIT_FSIZE", thumbnail_worker.EJN_MAX_PREVIEW_BYTES),
                mock.call("RLIMIT_NOFILE", 16),
                mock.call("RLIMIT_CORE", 0),
                mock.call("RLIMIT_AS", thumbnail_worker.EJN_LINUX_ADDRESS_SPACE_LIMIT),
            ],
        )

    def test_darwin_arm64_uses_bounded_pillow_headroom(self):
        with mock.patch.object(thumbnail_worker.sys, "platform", "darwin"), mock.patch.object(
            thumbnail_worker.platform, "machine", return_value="arm64"
        ), mock.patch.object(thumbnail_worker, "_set_limit") as set_limit:
            thumbnail_worker.apply_limits()

        self.assertEqual(
            set_limit.call_args_list[-1],
            mock.call("RLIMIT_AS", thumbnail_worker.EJN_DARWIN_ADDRESS_SPACE_LIMIT),
        )

    def test_unsupported_platform_fails_before_setting_limits(self):
        with mock.patch.object(thumbnail_worker.sys, "platform", "darwin"), mock.patch.object(
            thumbnail_worker.platform, "machine", return_value="x86_64"
        ), mock.patch.object(thumbnail_worker, "_set_limit") as set_limit:
            with self.assertRaisesRegex(RuntimeError, "unsupported thumbnail-worker platform"):
                thumbnail_worker.apply_limits()

        set_limit.assert_not_called()


if __name__ == "__main__":
    unittest.main()
