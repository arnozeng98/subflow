"""
Executable package entrypoint.

Running `python -m subflow` should behave exactly like the previous compatibility
wrapper, but without requiring a top-level helper file to live beside the
package forever.
"""

from .main import main


if __name__ == "__main__":
  main()