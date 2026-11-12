# x99-check

Checklist và script kiểm tra bộ **main X99 dual + 2× Xeon E5-2686 v4 + 4×32GB DDR4 ECC REG 2133** trước khi mua đồ cũ, không bảo hành.

Tại chỗ mất khoảng **30 phút**: 5 phút nhìn, 2 phút vào BIOS, 15–20 phút chạy script.

---

## 0. Tối trước khi đi

- [ ] Nhắn người bán **ráp sẵn cho máy chạy được** bằng nguồn, VGA và ổ cứng có Windows của họ. Xeon không có card đồ hoạ tích hợp nên không có VGA là không lên hình.
- [ ] Hỏi họ dùng **Windows bản gì**. **Windows Home chỉ dùng được 1 CPU**, nên script sẽ chỉ thấy 1 con. Khi đó phải xem thêm trong BIOS hoặc boot USB Linux (mục 5).
- [ ] Nếu họ không ráp được thì tự mang: nguồn có **2 đầu cắm 8-pin cho CPU (EPS)**, 1 VGA bất kỳ, và USB Ubuntu (mục 5).
- [ ] Mang điện thoại để chụp tem RAM, thêm đèn pin.

## 1. Nhìn bằng mắt (5 phút, trước khi bật máy)

- [ ] **Tên main** in trên bo: `HUANANZHI X99-F8D…` hay không có tên (main OEM, rẻ hơn khoảng 1 triệu).
- [ ] Tụ không phồng, không xì. Không gỉ sét. Không cháy xém quanh socket CPU và cụm VRM (mấy cục cuộn cảm cạnh socket).
- [ ] **Tem 4 thanh RAM**: cùng hãng, cùng mã. Trên tem có đoạn `PC4-2133P-R…` (RDIMM) hoặc `PC4-2133P-L…` (LRDIMM). 4 thanh phải **cùng chữ R hoặc cùng chữ L**, không được trộn. Chụp lại cả 4 tem.
- [ ] RAM chia đều 2 bên, mỗi CPU 2 thanh.
- [ ] 2 tản gắn chắc, quạt quay êm.

## 2. BIOS (2 phút)

Bật máy, bấm `Del` liên tục.

- [ ] Thấy **2 CPU**, ở mục Processor hoặc CPU Information.
- [ ] Tổng RAM **131072 MB** (= 128GB).

## 3. Chạy script trên Windows (15–20 phút)

**Tải về, chọn 1 trong 3 cách:**

**A.** Có mạng: mở PowerShell (`Win + R` → gõ `powershell` → Enter), dán dòng này:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; iwr -useb https://github.com/toanbku/x99-check/archive/refs/heads/main.zip -OutFile $env:TEMP\x99.zip; Expand-Archive $env:TEMP\x99.zip $env:TEMP -Force; Start-Process "$env:TEMP\x99-check-main\windows\run.bat"
```

**B.** Mở trình duyệt vào `github.com/toanbku/x99-check` → **Code** → **Download ZIP** → giải nén → vào thư mục `windows` → bấm đúp `run.bat`.

**C.** Máy có git: `git clone https://github.com/toanbku/x99-check`, rồi bấm đúp `windows\run.bat`.

Windows hỏi quyền Admin thì bấm **Yes**. Nếu hiện "Windows protected your PC" thì bấm **More info** → **Run anyway**.

**Script tự làm:**

1. Đọc Windows, main, BIOS, 2 CPU, từng thanh RAM (hãng, mã, RDIMM/LRDIMM, bus) rồi so với cấu hình người bán nói.
2. Xem RAM có chia đều cho 2 CPU không.
3. Xem log Windows 90 ngày gần nhất có lỗi phần cứng hay màn hình xanh không.
4. **Test RAM**: ghi 6 kiểu dữ liệu lên khoảng 85% RAM đang trống rồi đọc lại, sai 1 bit cũng bắt được. Mất khoảng 2–4 phút.
5. **Chạy nặng hết 72 luồng trong 10 phút**: kiểm tra CPU tính có sai không, xung có bị tụt không (tụt là dấu hiệu quá nhiệt, tản kém, hoặc main/nguồn yếu).
6. Kiểm tra Windows có ghi lỗi phần cứng (WHEA/ECC) trong lúc test không.

Chạy xong, báo cáo được lưu ra Desktop, tên `x99-report-….txt`.

> Windows không có sẵn cách đọc nhiệt độ CPU. Muốn xem nhiệt thật thì mở thêm **HWiNFO64** bản portable (hwinfo.com), chọn **Sensors-only**, rồi xem dòng *CPU Package*. Khi chạy nặng mà dưới khoảng 80°C là ổn.

Muốn thử nhanh 1 phút thì mở PowerShell trong thư mục `windows` và chạy:
`powershell -ExecutionPolicy Bypass -File check.ps1 -Quick`

## 4. Đọc kết quả

Mỗi dòng có nhãn `[OK]`, `[CHU Y]` (chú ý) hoặc `[LOI]` (lỗi). Cuối cùng có mục **TONG KET** gom hết lại.

| Thấy gì | Nghĩa là | Nên làm |
|---|---|---|
| Máy **tắt ngang / treo / màn hình xanh** khi đang test | Lỗi nặng nhất: CPU, RAM, main hoặc nguồn | Thử lại 1 lần. Nếu đang dùng nguồn của người bán thì có thể lỗi do nguồn, đổi nguồn khác thử. Vẫn bị thì **bỏ** |
| `[LOI] Chi nhan 1/2 CPU` | CPU chết, chân socket cong hoặc main lỗi | **Bỏ**. Riêng Windows Home thì xem BIOS / Linux trước |
| `[LOI] RAM SAI DU LIEU` hoặc `loi phan cung (WHEA)` khi test | Có thanh RAM lỗi | Rút từng thanh ra test lại để tìm thanh lỗi, rồi trừ tiền thanh đó |
| `[LOI] CPU TINH SAI` | CPU, main hoặc nguồn chạy không ổn định | **Bỏ** |
| `[LOI] Tron RDIMM voi LRDIMM` | 2 loại RAM không cắm chung được | Bỏ, hoặc bắt đổi cho đồng bộ |
| `[LOI] Tong RAM chi ...GB` / `Thay 3 thanh` | Thanh RAM chết hoặc khe RAM hỏng | Đổi chỗ thanh để biết lỗi do thanh hay do khe |
| `[CHU Y] Xung CPU tut` | Quá nhiệt (keo khô, tản lỏng) hoặc main/nguồn yếu | Xem nhiệt bằng HWiNFO. Thay keo là hết thì trừ chút tiền |
| `[CHU Y] RAM khong dong bo` | 4 thanh khác mã | Vẫn chạy được, nhưng là lý do để bớt giá |
| `[CHU Y] Co thanh khong phai Samsung` | Khác lời người bán | Bớt giá nhẹ |
| `[CHU Y] Windows tung ghi ... WHEA / man hinh xanh` | Trước đây máy từng lỗi | Hỏi người bán lý do |

## 4b. Kiểm tra ổ cứng (script riêng, ~1–2 phút mỗi ổ)

Script này chạy riêng, không liên quan script ở mục 3. Dán vào PowerShell:

```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12'; iwr -useb https://github.com/toanbku/x99-check/archive/refs/heads/main.zip -OutFile $env:TEMP\x99.zip; Expand-Archive $env:TEMP\x99.zip $env:TEMP -Force; Start-Process "$env:TEMP\x99-check-main\windows\disk.bat"
```

Đã tải ZIP rồi thì bấm đúp `windows\disk.bat` là xong.

Script **chỉ đọc** ổ, cộng thêm ghi **1 file tạm** (2GB) vào chỗ còn trống rồi tự xoá. Dữ liệu có sẵn trên ổ không bị đụng tới. Với mỗi ổ, script làm mấy việc sau:

1. Đọc tên, serial, loại ổ (HDD / SSD / NVMe), xem Windows đánh giá ổ ra sao.
2. Đọc **SMART** (bộ thông số sức khoẻ ổ tự ghi lại): số giờ đã chạy, số lần bật, sector hỏng hoặc đang chờ xử lý, **% tuổi thọ còn lại của SSD**, nhiệt độ.
3. Xem log Windows 90 ngày gần nhất có báo bad block, phải đọc lại hay ổ bị reset không.
4. **Đọc thử bề mặt ổ**: đo tốc độ ở đầu/giữa/cuối ổ, rồi đọc rải rác 400 chỗ khắp ổ để tìm chỗ đọc lỗi hoặc đọc chậm (dấu hiệu sắp có bad sector).
5. **Ghi rồi đọc lại** file tạm, so từng byte, đo luôn tốc độ ghi/đọc thật.

| Thấy gì | Nghĩa là |
|---|---|
| `SMART BAO O SAP HONG`, `Current Pending`, `Offline Uncorrectable`, `DOC LOI ... (bad sector)` | Ổ đang hỏng, **bỏ** |
| `SAI DU LIEU` khi ghi rồi đọc lại | Ổ, cáp hoặc RAM có lỗi, **bỏ** (hoặc thử lại bằng cáp khác) |
| `Reallocated` vài sector | Ổ từng có sector hỏng và đã thay thế. Còn dùng được nhưng nên bớt giá, đừng để dữ liệu quan trọng |
| `SSD con xx% tuoi tho` | Dưới 30% là nên bớt giá, dưới 10% thì bỏ |
| `Da chay ... gio` | HDD trên 35.000 giờ (khoảng 4 năm bật liên tục) là đã chạy nhiều |
| `UDMA CRC` | Thường do dây SATA lỏng hoặc xấu, không hẳn do ổ |
| `Doc/Ghi cham bat thuong` | HDD đọc dưới 50MB/s, SSD dưới 200MB/s, NVMe dưới 500MB/s là có vấn đề |

Tuỳ chọn: `-DiskNumber 1` chỉ test ổ số 1. `-FullRead` đọc hết bề mặt ổ (HDD 1TB mất khoảng 2 tiếng). `-NoWrite` không ghi file tạm. `-WriteTestGB 4` ghi file tạm 4GB.

Muốn xem SMART đầy đủ hơn thì dùng thêm **CrystalDiskInfo** (crystalmark.info).

## 5. Dự phòng: USB Ubuntu

Dùng khi máy **không có Windows**, hoặc là **Windows Home** (chỉ thấy 1 CPU).

**Chuẩn bị trên Mac:**

1. Tải Ubuntu 24.04 Desktop ISO ở ubuntu.com/download/desktop (khoảng 6GB).
2. Ghi ra USB từ 8GB trở lên bằng balenaEtcher (etcher.balena.io).

**Tại chỗ:**

1. Cắm USB, bật máy rồi bấm `F11` hoặc `F12` (tuỳ main) để chọn boot từ USB → **Try Ubuntu**.
2. Cắm dây mạng LAN cho dễ, mở Terminal (`Ctrl + Alt + T`) rồi chạy:

```bash
wget -O check.sh https://raw.githubusercontent.com/toanbku/x99-check/main/linux/check.sh && sudo bash check.sh
```

Không có mạng thì chép sẵn file `linux/check.sh` vào 1 USB khác, cắm vào rồi chạy `sudo bash /media/ubuntu/<tên-USB>/check.sh`.

Bản Linux test giống bản Windows, thêm mấy cái:

- đọc được **nhiệt độ CPU thật**
- đọc được **bộ đếm lỗi ECC** của RAM
- thấy đủ 2 CPU kể cả khi máy đang cài Windows Home

Có mạng thì nó tự cài `stress-ng` để test nặng hơn. Không có mạng thì dùng bộ test dự phòng viết bằng Python.

## 6. Dự phòng 2: memtest86+

Chỉ test RAM, nhưng test được **100% RAM** (Windows chỉ test được phần đang trống). Tải ISO ở memtest.org, ghi ra USB bằng Etcher, boot vào là tự chạy. Cho chạy ít nhất 1 lượt (Pass) không báo lỗi. Với 128GB, 1 lượt mất khoảng 1–2 tiếng, nên chỉ dùng khi có thời gian.

---

## Tuỳ chỉnh khi cấu hình khác

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File check.ps1 -ExpectCpu 2680 -ExpectThreads 56 -ExpectRamGB 64 -ExpectDimmGB 16 -ExpectBrand Hynix -StressMinutes 20 -MemPasses 3
```

Linux:

```bash
sudo EXPECT_CPU=2680 EXPECT_THREADS=56 EXPECT_RAM_GB=64 EXPECT_DIMM_GB=16 EXPECT_BRAND=Hynix STRESS_MIN=20 bash check.sh
```

Mã thoát: `0` = không thấy lỗi, `1` = có `[LOI]` hoặc `[CHU Y]`, `2` = bản thân script bị lỗi.

## Script không làm được

- Không đọc được nhiệt độ CPU thật trên Windows. Muốn xem thì dùng HWiNFO hoặc chạy bản Linux.
- Trên Windows chỉ test được phần RAM đang trống (khoảng 85%). Muốn test 100% thì dùng memtest86+.
- Không test cổng USB, LAN, khe PCIe, khe M.2. Cần thì cắm thử bằng tay.
- Thông tin RAM là do main báo lên, nên vẫn phải nhìn tem thật.

## Code

- `windows/check.ps1`: Windows PowerShell 5.1, không cần cài thêm gì. Test RAM và chạy nặng CPU viết bằng C# nhúng trong script. Thread được ghim theo processor group để chạy được cả 2 CPU, vì Windows chia máy trên 64 luồng thành nhiều nhóm.
- `windows/run.bat`: tự xin quyền Admin rồi chạy `check.ps1`.
- `linux/check.sh`: bản cho Ubuntu Live, dùng `stress-ng` nếu có, không thì dùng Python.
- `.github/workflows/test.yml`: CI chạy thử cả 2 script trên máy Windows/Linux của GitHub, có cố tình gây lỗi RAM/CPU để chắc script bắt được.
