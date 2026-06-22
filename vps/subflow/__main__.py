"""
可执行包入口。

执行 `python -m subflow` 的行为应与此前的兼容性包装脚本完全一致，但不再需要
在包旁边长期保留一个顶层的辅助文件。
"""

from .main import main


if __name__ == "__main__":
  main()