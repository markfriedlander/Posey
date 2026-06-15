TITLE: More About PyTorch
FILETYPE: md
UNITS: 232
READER-OPENS-AT-UNIT-INDEX: 0 (no skip)
READER-STOPS-AT-UNIT-INDEX: 232 (no trim)
----
#0010  prose | PyTorch Logo
#0020  horizontal_rule | 
#0030  prose | PyTorch is a Python package that provides two high-level features:
#0040  list_item[•] | Tensor computation (like NumPy) with strong GPU acceleration
#0050  list_item[•] | Deep neural networks built on a tape-based autograd system
#0060  prose | You can reuse your favorite Python packages such as NumPy, SciPy, and Cython to extend PyTorch when needed.
#0070  prose | Our trunk health (Continuous Integration signals) can be found at hud.pytorch.org.
#0080  list_item[•] | More About PyTorch
#0090  list_item[•] | A GPU-Ready Tensor Library
#0100  list_item[•] | Dynamic Neural Networks: Tape-Based Autograd
#0110  list_item[•] | Python First
#0120  list_item[•] | Imperative Experiences
#0130  list_item[•] | Fast and Lean
#0140  list_item[•] | Extensions Without Pain
#0150  list_item[•] | Installation
#0160  list_item[•] | Binaries
#0170  list_item[•] | NVIDIA Jetson Platforms
#0180  list_item[•] | From Source
#0190  list_item[•] | Prerequisites
#0200  list_item[•] | NVIDIA CUDA Support
#0210  list_item[•] | AMD ROCm Support
#0220  list_item[•] | Intel GPU Support
#0230  list_item[•] | Get the PyTorch Source
#0240  list_item[•] | Install Dependencies
#0250  list_item[•] | Install PyTorch
#0260  list_item[•] | Adjust Build Options (Optional)
#0270  list_item[•] | Docker Image
#0280  list_item[•] | Using pre-built images
#0290  list_item[•] | Building the image yourself
#0300  list_item[•] | Building the Documentation
#0310  list_item[•] | Troubleshooting CI Errors
#0320  list_item[•] | Building a PDF
#0330  list_item[•] | Previous Versions
#0340  list_item[•] | Getting Started
#0350  list_item[•] | Resources
#0360  list_item[•] | Communication
#0370  list_item[•] | Releases and Contributing
#0380  list_item[•] | The Team
#0390  list_item[•] | License
#0400  heading(L2) | More About PyTorch
#0410  prose | Learn the basics of PyTorch
#0420  prose | At a granular level, PyTorch is a library that consists of the following components:
#0430  prose | | Component | Description | | ---- | --- | | torch | A Tensor library like NumPy, with strong GPU support | | torch.autograd | A tape-based automatic differentiation library that supports all differentiable Tensor operations in torch | | torch.jit | A compilation stack (TorchScript) to create serializable and optimizable models from PyTorch code | | torch.nn | A neural networks library deeply integrated with autograd designed for maximum flexibility | | torch.multiprocessing | Python multiprocessing, but with magical memory sharing of torch Tensors across processes. Useful for data loading and Hogwild training | | torch.utils | DataLoader and other utility functions for convenience |
#0440  prose | Usually, PyTorch is used either as:
#0450  list_item[•] | A replacement for NumPy to use the power of GPUs.
#0460  list_item[•] | A deep learning research platform that provides maximum flexibility and speed.
#0470  prose | Elaborating Further:
#0480  heading(L3) | A GPU-Ready Tensor Library
#0490  prose | If you use NumPy, then you have used Tensors (a.k.a. ndarray).
#0500  prose | Tensor illustration
#0510  prose | PyTorch provides Tensors that can live either on the CPU or the GPU and accelerates the computation by a huge amount.
#0520  prose | We provide a wide variety of tensor routines to accelerate and fit your scientific computation needs such as slicing, indexing, mathematical operations, linear algebra, reductions. And they are fast!
#0530  heading(L3) | Dynamic Neural Networks: Tape-Based Autograd
#0540  prose | PyTorch has a unique way of building neural networks: using and replaying a tape recorder.
#0550  prose | Most frameworks such as TensorFlow, Theano, Caffe, and CNTK have a static view of the world. One has to build a neural network and reuse the same structure again and again. Changing the way the network behaves means that one has to start from scratch.
#0560  prose | With PyTorch, we use a technique called reverse-mode auto-differentiation, which allows you to change the way your network behaves arbitrarily with zero lag or overhead. Our inspiration comes from several research papers on this topic, as well as current and past work such as torch-autograd, autograd, Chainer, etc.
#0570  prose | While this technique is not unique to PyTorch, it's one of the fastest implementations of it to date. You get the best of speed and flexibility for your crazy research.
#0580  prose | Dynamic graph
#0590  heading(L3) | Python First
#0600  prose | PyTorch is not a Python binding into a monolithic C++ framework. It is built to be deeply integrated into Python. You can use it naturally like you would use NumPy / SciPy / scikit-learn etc. You can write your new neural network layers in Python itself, using your favorite libraries and use packages such as Cython and Numba. Our goal is to not reinvent the wheel where appropriate.
#0610  heading(L3) | Imperative Experiences
#0620  prose | PyTorch is designed to be intuitive, linear in thought, and easy to use. When you execute a line of code, it gets executed. There isn't an asynchronous view of the world. When you drop into a debugger or receive error messages and stack traces, understanding them is straightforward. The stack trace points to exactly where your code was defined. We hope you never spend hours debugging your code because of bad stack traces or asynchronous and opaque execution engines.
#0630  heading(L3) | Fast and Lean
#0640  prose | PyTorch has minimal framework overhead. We integrate acceleration libraries such as Intel MKL and NVIDIA (cuDNN, NCCL) to maximize speed. At the core, its CPU and GPU Tensor and neural network backends are mature and have been tested for years.
#0650  prose | Hence, PyTorch is quite fast — whether you run small or large neural networks.
#0660  prose | The memory usage in PyTorch is extremely efficient compared to Torch or some of the alternatives. We've written custom memory allocators for the GPU to make sure that your deep learning models are maximally memory efficient. This enables you to train bigger deep learning models than before.
#0670  heading(L3) | Extensions Without Pain
#0680  prose | Writing new neural network modules, or interfacing with PyTorch's Tensor API, was designed to be straightforward and with minimal abstractions.
#0690  prose | You can write new neural network layers in Python using the torch API or your favorite NumPy-based libraries such as SciPy.
#0700  prose | If you want to write your layers in C/C++, we provide a convenient extension API that is efficient and with minimal boilerplate. No wrapper code needs to be written. You can see a tutorial here and an example here.
#0710  heading(L2) | Installation
#0720  heading(L3) | Binaries
#0730  prose | Commands to install binaries via Conda or pip wheels are on our website: https://pytorch.org/get-started/locally/
#0740  heading(L4) | NVIDIA Jetson Platforms
#0750  prose | Python wheels for NVIDIA's Jetson Nano, Jetson TX1/TX2, Jetson Xavier NX/AGX, and Jetson AGX Orin are provided here and the L4T container is published here
#0760  prose | They require JetPack 4.2 and above, and @dusty-nv and @ptrblck are maintaining them.
#0770  heading(L3) | From Source
#0780  heading(L4) | Prerequisites
#0790  prose | If you are installing from source, you will need:
#0800  list_item[•] | Python 3.10 or later
#0810  list_item[•] | A compiler that fully supports C++20, such as clang or gcc (gcc 11.3.0 or newer is required, on Linux)
#0820  list_item[•] | Visual Studio or Visual Studio Build Tool (Windows only)
#0830  list_item[•] | At least 10 GB of free disk space
#0840  list_item[•] | 30-60 minutes for the initial build (subsequent rebuilds are much faster)
#0850  prose | \ PyTorch CI uses Visual C++ BuildTools, which come with Visual Studio Enterprise, Professional, or Community Editions. You can also install the build tools from https://visualstudio.microsoft.com/visual-cpp-build-tools/. The build tools do not* come with Visual Studio Code by default.
#0860  prose | An example of environment setup is shown below:
#0870  list_item[•] | Linux:
#0880  code | $ source <CONDA_INSTALL_DIR>/bin/activate\n$ conda create -y -n <CONDA_NAME>\n$ conda activate <CONDA_NAME>
#0890  list_item[•] | Windows:
#0900  code | $ source <CONDA_INSTALL_DIR>\Scripts\activate.bat\n$ conda create -y -n <CONDA_NAME>\n$ conda activate <CONDA_NAME>\n$ call "C:\Program Files\Microsoft Visual Studio\<VERSION>\Community\VC\Auxiliary\Build\vcvarsall.bat" x64
#0910  prose | A conda environment is not required. You can also do a PyTorch build in a standard virtual environment, e.g., created with tools like uv, provided your system has installed all the necessary dependencies unavailable as pip packages (e.g., CUDA, MKL.)
#0920  heading(L5) | NVIDIA CUDA Support
#0930  prose | If you want to compile with CUDA support, select a supported version of CUDA from our support matrix, then install the following:
#0940  list_item[•] | NVIDIA CUDA
#0950  list_item[•] | NVIDIA cuDNN v9.0 or above
#0960  list_item[•] | Compiler compatible with CUDA
#0970  prose | Note: You could refer to the cuDNN Support Matrix for cuDNN versions with the various supported CUDA, CUDA driver, and NVIDIA hardware.
#0980  prose | If you want to disable CUDA support, export the environment variable USE_CUDA=0. Other potentially useful environment variables may be found in setup.py. If CUDA is installed in a non-standard location, set PATH so that the nvcc you want to use can be found (e.g., export PATH=/usr/local/cuda-12.8/bin:$PATH).
#0990  prose | If you are building for NVIDIA's Jetson platforms (Jetson Nano, TX1, TX2, AGX Xavier), Instructions to install PyTorch for Jetson Nano are available here
#1000  heading(L5) | AMD ROCm Support
#1010  prose | If you want to compile with ROCm support, install
#1020  list_item[•] | AMD ROCm 4.0 and above installation
#1030  list_item[•] | ROCm is currently supported only for Linux systems.
#1040  prose | By default the build system expects ROCm to be installed in /opt/rocm. If ROCm is installed in a different directory, the ROCMPATH environment variable must be set to the ROCm installation directory. The build system automatically detects the AMD GPU architecture. Optionally, the AMD GPU architecture can be explicitly set with the PYTORCHROCM_ARCH environment variable AMD GPU architecture
#1050  prose | If you want to disable ROCm support, export the environment variable USE_ROCM=0. Other potentially useful environment variables may be found in setup.py.
#1060  heading(L5) | Intel GPU Support
#1070  prose | If you want to compile with Intel GPU support, follow these
#1080  list_item[•] | PyTorch Prerequisites for Intel GPUs instructions.
#1090  list_item[•] | Intel GPU is supported for Linux and Windows.
#1100  prose | If you want to disable Intel GPU support, export the environment variable USE_XPU=0. Other potentially useful environment variables may be found in setup.py.
#1110  heading(L4) | Get the PyTorch Source
#1120  code | git clone https://github.com/pytorch/pytorch\ncd pytorch\n# if you are updating an existing checkout\ngit submodule sync\ngit submodule update --init --recursive
#1130  heading(L4) | Install Dependencies
#1140  prose | Common
#1150  code | # Run this command from the PyTorch directory after cloning the source code using the “Get the PyTorch Source“ section above\npip install --group dev
#1160  prose | On Linux
#1170  code | pip install mkl-static mkl-include\n# CUDA only: Add LAPACK support for the GPU if needed\n# magma installation: run with active conda environment. specify CUDA version to install\n.ci/docker/common/install_magma_conda.sh 12.4\n\n# (optional) If using torch.compile with inductor/triton, install the matching version of triton\n# Run from the pytorch directory after cloning\n# For Intel GPU support, please explicitly `export USE_XPU=1` before running command.\nmake triton
#1180  prose | On Windows
#1190  code | pip install mkl-static mkl-include\n# Add these packages if torch.distributed is needed.\n# Distributed package support on Windows is a prototype feature and is subject to changes.\nconda install -c conda-forge libuv=1.51
#1200  heading(L4) | Install PyTorch
#1210  prose | On Linux
#1220  prose | If you're compiling for AMD ROCm then first run this command:
#1230  code | # Only run this if you're compiling for ROCm\npython tools/amd_build/build_amd.py
#1240  prose | Install PyTorch
#1250  code | # the CMake prefix for conda environment\nexport CMAKE_PREFIX_PATH="${CONDA_PREFIX:-'$(dirname $(which conda))/../'}:${CMAKE_PREFIX_PATH}"\npython -m pip install --no-build-isolation -v -e .\n\n# the CMake prefix for non-conda environment, e.g. Python venv\n# call following after activating the venv\nexport CMAKE_PREFIX_PATH="${VIRTUAL_ENV}:${CMAKE_PREFIX_PATH}"
#1260  prose | On macOS
#1270  code | python -m pip install --no-build-isolation -v -e .
#1280  prose | On Windows
#1290  prose | If you want to build legacy python code, please refer to Building on legacy code and CUDA
#1300  prose | CPU-only builds
#1310  prose | In this mode PyTorch computations will run on your CPU, not your GPU.
#1320  code | python -m pip install --no-build-isolation -v -e .
#1330  prose | Note on OpenMP: The desired OpenMP implementation is Intel OpenMP (iomp). In order to link against iomp, you'll need to manually download the library and set up the building environment by tweaking CMAKEINCLUDEPATH and LIB. The instruction here is an example for setting up both MKL and Intel OpenMP. Without these configurations for CMake, Microsoft Visual C OpenMP runtime (vcomp) will be used.
#1340  prose | CUDA based build
#1350  prose | In this mode PyTorch computations will leverage your GPU via CUDA for faster number crunching
#1360  prose | NVTX is needed to build PyTorch with CUDA. NVTX is a part of CUDA distributive, where it is called "Nsight Compute". To install it onto an already installed CUDA run CUDA installation once again and check the corresponding checkbox. Make sure that CUDA with Nsight Compute is installed after Visual Studio.
#1370  prose | Currently, VS 2017 / 2019, and Ninja are supported as the generator of CMake. If ninja.exe is detected in PATH, then Ninja will be used as the default generator, otherwise, it will use VS 2017 / 2019. If Ninja is selected as the generator, the latest MSVC will get selected as the underlying toolchain.
#1380  prose | Additional libraries such as Magma, oneDNN, a.k.a. MKLDNN or DNNL, and Sccache are often needed. Please refer to the installation-helper to install them.
#1390  prose | You can refer to the buildpytorch.bat script for some other environment variables configurations
#1400  code | cmd\n\n:: Set the environment variables after you have downloaded and unzipped the mkl package,\n:: else CMake would throw an error as `Could NOT find OpenMP`.\nset CMAKE_INCLUDE_PATH={Your directory}\mkl\include\nset LIB={Your directory}\mkl\lib;%LIB%\n\n:: Read the content in the previous section carefully before you proceed.\n:: [Optional] If you want to override the underlying toolset used by Ninja and Visual Studio with CUDA, please run the following script block.\n:: "Visual Studio 2019 Developer Command Prompt" will be run automatically.\n:: Make sure you have CMake >= 3.12 before you do this when you use the Visual Studio generator.\nset CMAKE_GENERATOR_TOOLSET_VERSION=14.27\nset DISTUTILS_USE_SDK=1\nfor /f "usebackq tokens=*" %i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -version [15^,17^) -products * -latest -property installationPath`) do call "%i\VC\Auxiliary\Build\vcvarsall.bat" x64 -vcvars_ver=%CMAKE_GENERATOR_TOOLSET_VERSION%\n\n:: [Optional] If you want to override the CUDA host compiler\nset CUDAHOSTCXX=C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Tools\MSVC\14.27.29110\bin\HostX64\x64\cl.exe\n\npython -m pip install --no-build-isolation -v -e .
#1410  prose | Intel GPU builds
#1420  prose | In this mode PyTorch with Intel GPU support will be built.
#1430  prose | Please make sure the common prerequisites as well as the prerequisites for Intel GPU are properly installed and the environment variables are configured prior to starting the build. For build tool support, Visual Studio 2022 is required.
#1440  prose | Then PyTorch can be built with the command:
#1450  code | :: CMD Commands:\n:: Set the CMAKE_PREFIX_PATH to help find corresponding packages\n:: %CONDA_PREFIX% only works after `conda activate custom_env`\n\nif defined CMAKE_PREFIX_PATH (\n    set "CMAKE_PREFIX_PATH=%CONDA_PREFIX%\Library;%CMAKE_PREFIX_PATH%"\n) else (\n    set "CMAKE_PREFIX_PATH=%CONDA_PREFIX%\Library"\n)\n\npython -m pip install --no-build-isolation -v -e .
#1460  heading(L5) | Adjust Build Options (Optional)
#1470  prose | You can adjust the configuration of cmake variables optionally (without building first), by doing the following. For example, adjusting the pre-detected directories for CuDNN or BLAS can be done with such a step.
#1480  prose | On Linux
#1490  code | export CMAKE_PREFIX_PATH="${CONDA_PREFIX:-'$(dirname $(which conda))/../'}:${CMAKE_PREFIX_PATH}"\nCMAKE_ONLY=1 python setup.py build\nccmake build  # or cmake-gui build
#1500  prose | On macOS
#1510  code | export CMAKE_PREFIX_PATH="${CONDA_PREFIX:-'$(dirname $(which conda))/../'}:${CMAKE_PREFIX_PATH}"\nMACOSX_DEPLOYMENT_TARGET=11.0 CMAKE_ONLY=1 python setup.py build\nccmake build  # or cmake-gui build
#1520  heading(L3) | Docker Image
#1530  heading(L4) | Using pre-built images
#1540  prose | You can also pull a pre-built docker image from Docker Hub and run with docker v23.0+
#1550  code | docker run --gpus all --rm -ti --ipc=host pytorch/pytorch:latest
#1560  prose | Please note that PyTorch uses shared memory to share data between processes, so if torch multiprocessing is used (e.g. for multithreaded data loaders) the default shared memory segment size that container runs with is not enough, and you should increase shared memory size either with --ipc=host or --shm-size command line options to nvidia-docker run.
#1570  heading(L4) | Building the image yourself
#1580  prose | NOTE: Must be built with a Docker version >= 23.0
#1590  prose | The Dockerfile is supplied to build images with CUDA 12.1 support and cuDNN v9. You can pass PYTHON_VERSION=x.y make variable to specify which Python version is to be used by Miniconda, or leave it unset to use the default, as the Dockerfile uses system Python.
#1600  code | make -f docker.Makefile\n# images are tagged as docker.io/${your_docker_username}/pytorch
#1610  prose | You can also pass the CMAKE_VARS="..." environment variable to specify additional CMake variables to be passed to CMake during the build. See setup.py for the list of available variables.
#1620  code | make -f docker.Makefile
#1630  heading(L3) | Building the Documentation
#1640  prose | To build documentation in various formats, you will need Sphinx and the pytorchsphinxtheme2.
#1650  prose | Before you build the documentation locally, ensure torch is installed in your environment. For small fixes, you can install the nightly version as described in Getting Started.
#1660  prose | For more complex fixes, such as adding a new module and docstrings for the new module, you might need to install torch from source. See Docstring Guidelines for docstring conventions.
#1670  code | cd docs/\npip install -r requirements.txt\nmake html\nmake serve
#1680  prose | Run make to get a list of all available output formats.
#1690  prose | If you get a katex error run npm install katex. If it persists, try npm install -g katex
#1700  blockquote | [!NOTE] If you see a numpy incompatibility error, run: pip install 'numpy<2'
#1710  heading(L4) | Troubleshooting CI Errors
#1720  prose | Your build may show errors you didn't have locally - here's how to find the errors relevant to the docs.
#1730  prose | If the build has any errors, you will see something like this on the PR:
#1740  prose | Any doc-related errors will occur in jobs that include "doc" somewhere in the title. It doesn't look like any of these jobs are relevant to our docs.
#1750  prose | Let's take a look anyway. Click on the job to see the logs:
#1760  prose | And we can be sure that this job does not involve docs.
#1770  prose | Looking at this build, we can see these jobs are relevant to our docs - and they didn't have any errors:
#1780  prose | You might also see a comment on the PR like this:
#1790  prose | We can see that some of these issues are relevant to our docs.
#1800  prose | Open the logs by clicking on the gh link:
#1810  prose | And here we can see there is a doc-related error:
#1820  prose | You can always find the relevant doc builds by going to the Checks tab on your PR, and scrolling down to pull.
#1830  prose | You can either click through or toggle the accordion to see all of the jobs here, where you can see the docs jobs highlighted:
#1840  prose | If you click through, you'll see the doc jobs at the bottom, like this:
#1850  heading(L4) | Building a PDF
#1860  prose | To compile a PDF of all PyTorch documentation, ensure you have texlive and LaTeX installed. On macOS, you can install them using:
#1870  code | brew install --cask mactex
#1880  prose | To create the PDF:
#1890  list_item[1.] | Run:
#1900  code |    make latexpdf
#1910  prose | This will generate the necessary files in the build/latex directory.
#1920  list_item[2.] | Navigate to this directory and execute:
#1930  code |    make LATEXOPTS="-interaction=nonstopmode"
#1940  prose | This will produce a pytorch.pdf with the desired content. Run this command one more time so that it generates the correct table of contents and index.
#1950  blockquote | [!NOTE] To view the Table of Contents, switch to the Table of Contents view in your PDF viewer.
#1960  heading(L3) | Previous Versions
#1970  prose | Installation instructions and binaries for previous PyTorch versions may be found on our website.
#1980  heading(L2) | Getting Started
#1990  prose | Pointers to get you started:
#2000  list_item[•] | Tutorials: get you started with understanding and using PyTorch
#2010  list_item[•] | Examples: easy to understand PyTorch code across all domains
#2020  list_item[•] | The API Reference
#2030  list_item[•] | Glossary
#2040  heading(L2) | Resources
#2050  list_item[•] | PyTorch.org
#2060  list_item[•] | PyTorch Tutorials
#2070  list_item[•] | PyTorch Examples
#2080  list_item[•] | PyTorch Models
#2090  list_item[•] | Intro to Deep Learning with PyTorch from Udacity
#2100  list_item[•] | Intro to Machine Learning with PyTorch from Udacity
#2110  list_item[•] | Deep Neural Networks with PyTorch from Coursera
#2120  list_item[•] | PyTorch Twitter
#2130  list_item[•] | PyTorch Blog
#2140  list_item[•] | PyTorch YouTube
#2150  heading(L2) | Communication
#2160  list_item[•] | Forums: Discuss implementations, research, etc. https://discuss.pytorch.org
#2170  list_item[•] | GitHub Issues: Bug reports, feature requests, install issues, RFCs, thoughts, etc.
#2180  list_item[•] | Slack: The PyTorch Slack hosts a primary audience of moderate to experienced PyTorch users and developers for general chat, online discussions, collaboration, etc. If you are a beginner looking for help, the primary medium is PyTorch Forums. If you need a slack invite, please fill this form: https://goo.gl/forms/PP1AGvNHpSaJP8to1
#2190  list_item[•] | Newsletter: No-noise, a one-way email newsletter with important announcements about PyTorch. You can sign-up here: https://eepurl.com/cbG0rv
#2200  list_item[•] | Facebook Page: Important announcements about PyTorch. https://www.facebook.com/pytorch
#2210  list_item[•] | For brand guidelines, please visit our website at pytorch.org
#2220  heading(L2) | Releases and Contributing
#2230  prose | Typically, PyTorch has three minor releases a year. Please let us know if you encounter a bug by filing an issue.
#2240  prose | We appreciate all contributions. If you are planning to contribute back bug-fixes, please do so without any further discussion.
#2250  prose | If you plan to contribute new features, utility functions, or extensions to the core, please first open an issue and discuss the feature with us. Sending a PR without discussion might end up resulting in a rejected PR because we might be taking the core in a different direction than you might be aware of.
#2260  prose | To learn more about making a contribution to PyTorch, please see our Contribution page. For more information about PyTorch releases, see Release page.
#2270  heading(L2) | The Team
#2280  prose | PyTorch is a community-driven project with several skillful engineers and researchers contributing to it.
#2290  prose | PyTorch is currently maintained by Soumith Chintala, Gregory Chanan, Dmytro Dzhulgakov, Edward Yang, Alban Desmaison, Piotr Bialecki and Nikita Shulga with major contributions coming from hundreds of talented individuals in various forms and means. A non-exhaustive but growing list needs to mention: Trevor Killeen, Sasank Chilamkurthy, Sergey Zagoruyko, Adam Lerer, Francisco Massa, Alykhan Tejani, Luca Antiga, Alban Desmaison, Andreas Koepf, James Bradbury, Zeming Lin, Yuandong Tian, Guillaume Lample, Marat Dukhan, Natalia Gimelshein, Christian Sarofeen, Martin Raison, Edward Yang, Zachary Devito.
#2300  prose | Note: This project is unrelated to hughperkins/pytorch with the same name. Hugh is a valuable contributor to the Torch community and has helped with many things Torch and PyTorch.
#2310  heading(L2) | License
#2320  prose | PyTorch has a BSD-style license, as found in the LICENSE file.
