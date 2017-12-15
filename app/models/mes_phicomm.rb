class MesPhicomm

  def self.check_sn(barcode_sn)
    sql = "select sn from txdb.phicomm_mes_001 where sn=?"
    records = PoReceipt.find_by_sql([sql, barcode_sn])
    if records.present?
      sn = records.first.sn
    else
      sn = 'N/A'
    end
    sn
  end

  def self.print_mac_addr(barcode_sn, printer_ip)
    sql = "select mac_add from txdb.phicomm_mes_001 where sn=?"
    records = PoReceipt.find_by_sql([sql, barcode_sn])
    if records.present?
      mac_add = records.first.mac_add
      print_mac_addr_label(mac_add, printer_ip)
    else
      mac_add = 'N/A'
    end
    mac_add
  end

  def self.print_mac_addr_label(mac_add, printer_ip)
    zpl_command = "
        ^XA~TA000~JSN^LT0^MNW^MTT^PON^PMN^LH0,0^JMA^PR4,4~SD15^JUS^LRN^CI0^XZ
        ^XA
        ^MMT
        ^PW900
        ^LL0600
        ^LS0
        ^BY4,3,71^FT48,295^BCN,,N,N
        ^FD>:#{mac_add}^FS
        ^FT116,210^A0N,25,24^FH
      dd}^FS
        ^FT51,208^AAN,27,15^FH
        ^FDSN:^FS
        ^PQ1,0,1,Y^XZ
    "
    s = TCPSocket.new(printer_ip, '9100')
    s.write zpl_command
    s.close
  end

  def self.print_sn(barcode_sn, printer_ip)
    sql = "select sn from txdb.phicomm_mes_001 where sn=?"
    records = PoReceipt.find_by_sql([sql, barcode_sn])
    if records.present?
      sn = records.first.sn
      print_sn_label(barcode_sn, printer_ip)
    else
      sn = 'N/A'
    end
    sn
  end

  def self.print_sn_label(sn, printer_ip)
    zpl_command = "
      ^XA~TA000~JSN^LT0^MNW^MTT^PON^PMN^LH0,0^JMA^PR4,4~SD15^JUS^LRN^CI0^XZ
      ^XA
      ^MMT
      ^PW900
      ^LL0600
      ^LS0
      ^BY4,3,71^FT48,295^BCN,,N,N
      ^FD>:#{sn}^FS
      ^FT116,210^A0N,25,24^FH
      ^FD#{sn}^FS
      ^FT51,208^AAN,27,15^FH
      ^FDSN:^FS
      ^PQ1,0,1,Y^XZ
    "
    s = TCPSocket.new(printer_ip, '9100')
    s.write zpl_command
    s.close
  end

  def self.print_color_box(barcode_sn, printer_ip)
    sql = "select mac_add from txdb.phicomm_mes_001 where sn=?"
    records = PoReceipt.find_by_sql([sql, barcode_sn])
    if records.present?
      mac_add = records.first.mac_add
      print_color_box_label(barcode_sn, printer_ip)
    else
      mac_add = 'N/A'
    end
    mac_add
  end

  def self.print_color_box_label(sn, printer_ip)
    zpl_command = "
      ^XA~TA000~JSN^LT0^MNW^MTT^PON^PMN^LH0,0^JMA^PR4,4~SD15^JUS^LRN^CI0^XZ
      ^XA
      ^MMT
      ^PW900
      ^LL0600
      ^LS0
      ^BY4,3,71^FT48,295^BCN,,N,N
      ^FD>:#{sn}^FS
      ^FT116,210^A0N,25,24^FH
      ^FD#{sn}^FS
      ^FT51,208^AAN,27,15^FH
      ^FDSN:^FS
      ^PQ1,0,1,Y^XZ
    "
    s = TCPSocket.new(printer_ip, '9100')
    s.write zpl_command
    s.close
  end

  def self.update_kcode(barcode, kcode)
    update_count = 0
    sql = "update txdb.phicomm_mes_001 set kcode='#{kcode}' where (sn='#{barcode}' or mac_add='#{barcode}')"
    begin
      update_count = PoReceipt.connection.execute(sql)
    rescue
    end
    update_count
  end

  def self.get_printer(pc_ip, program)
    # pc_ip
    # program
    # printer_ip
    # printer_port
    sql = "select printer_ip, printer_port from txdb.phicomm_mes_printer where pc_ip=? and program=?"
    records = PoReceipt.find_by_sql([sql, pc_ip, program])
    if records.present?
      return [records.first.printer_ip, records.first.printer_port]
    else
      sql = "insert into txdb.phicomm_mes_printer (pc_ip, program, printer_port) values ('#{pc_ip}','#{program}','9100')"
      PoReceipt.connection.execute(sql)
      return ['','9100']
    end
  end

  def self.update_printer(pc_ip, program, printer_ip, printer_port='9100')
    sql = "update txdb.phicomm_mes_printer set printer_ip='#{printer_ip}', printer_port='#{printer_port}' where pc_ip='#{pc_ip}' and program='#{program}'"
    PoReceipt.connection.execute(sql)
  end

end