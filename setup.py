from setuptools import setup
import nimporter

from os import path
this_directory = path.abspath(path.dirname(__file__))
with open(path.join(this_directory, 'README.md'), encoding='utf-8') as f:
    long_description = f.read()

setup(
    name = "bulksend",
    version = "0.1.0",
    author = "Marco Mengelkoch",
    description = "Nim / Python library to feed HTTP server quickly with custom messages",
    long_description = long_description,
    long_description_content_type = "text/markdown",
    keywords = "nim, tcp, http-client",
    url = "https://github.com/marcomq/bulksend",
    license = "MIT",
    classifiers = [
        "Environment::Console",
        "Programming Language::Python",
        "Intended Audience::Developers",
        "License::OSI Approved::MIT License"
    ],
    ext_modules=nimporter.build_nim_extensions(danger=True, exclude_dirs=["test"])
)