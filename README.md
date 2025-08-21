# 🔍 Duplicate Finder PC

A cross-platform desktop application to scan, detect, and manage duplicate files efficiently.  
Built with **Flutter (Dart)** for UI and logic, and integrated with **C++/CMake** for fast checksum computation.  

---

## ✨ Features
- 📂 **Directory Scan** – Choose any folder and scan for duplicate files.  
- ⚡ **Quick & Full Scan Modes** – Fast scan by metadata or deep scan using checksums.  
- 🧾 **Duplicate Grouping** – Files grouped by checksum, showing oldest file preserved.  
- 🗑️ **Recycle Bin Support** – Duplicates are moved to a safe `dupbin` folder instead of permanent deletion.  
- 📊 **Progress Updates** – Real-time progress shown during scanning.  
- 🔄 **Restore & Manage** – Restore deleted files or permanently remove them.  
- 🖥️ **Cross-Platform** – Works on Windows, Linux, and macOS (in development).  


## 🚀 Getting Started

### Prerequisites
- [Flutter SDK](https://docs.flutter.dev/get-started/install) (>=3.0.0)  
- [CMake](https://cmake.org/download/) & C++ build tools  
- [Dart](https://dart.dev/get-dart) installed with Flutter  

### Clone the Repository
```bash
git clone https://github.com/bharathvaj68/Duplicate-Finder-PC.git
cd Duplicate-Finder-PC
````

### Install Dependencies

```bash
flutter pub get
```

### Run the App

For desktop:

```bash
flutter run -d windows
```

(Replace `windows` with `linux` or `macos` as per your platform)

---

## 📂 Project Structure

```
Duplicate-Finder-PC/dupfile/
│── lib/                # Flutter app code (UI + logic)
│── cpp/                # C++ backend code for checksum & file ops
│── cmake/              # CMake configs for building native extensions
│── assets/             # Icons & other resources
│── README.md           # Project documentation
```

---

## 🛠️ Tech Stack

* **Flutter / Dart** – UI & State Management
* **C++ with CMake** – Native performance modules
* **SQLite** – Local storage of file metadata
* **Win32 / Platform Channels** – OS integration (Windows)

---

## 🧑‍💻 Contributing

Contributions are welcome!

1. Fork this repo
2. Create your feature branch (`git checkout -b feature/YourFeature`)
3. Commit your changes (`git commit -m 'Add new feature'`)
4. Push to branch (`git push origin feature/YourFeature`)
5. Open a Pull Request 🎉

---

## 📜 License

This project is licensed under the **MIT License** – free to use, modify, and distribute.

---

## 👨‍💻 Authors

* **[Bharathvaj V](https://github.com/bharathvaj68)**
* **[Arjun Aadhith BS](https://github.com/ArjunAadhith)**

```

