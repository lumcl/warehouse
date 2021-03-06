class MesTErpAccount < ActiveRecord::Base
  attr_accessor :ws_bal_qty #decimal
  attr_accessor :ws_alloc_qty #decimal
  attr_accessor :ws_locations #array
  attr_accessor :ws_movements #array

  self.table_name = :t_erp_account
  self.primary_key = :id
  establish_connection :leimes

  require 'java'
  java_import 'java.io.File'
  java_import 'java.io.FileOutputStream'
  java_import 'java.util.Properties'
  java_import 'com.sap.conn.jco.JCoDestination'
  java_import 'com.sap.conn.jco.JCoDestinationManager'
  java_import 'com.sap.conn.jco.ext.DestinationDataEventListener'
  java_import 'com.sap.conn.jco.ext.DestinationDataProvider'
  java_import 'com.sap.conn.jco.JCoContext'

  def self.start
    job_status = CronJob.kill('rails r MesTErpAccount.start', '540')
    if not job_status.eql?('job_still_running')
      check_mo_close
      adjustment
      mo_return
      mo_issue
      mes_overload
      #send_email('cronjob', 'rails r MesTErpAccount.start finish running')
    else
      send_email('cronjob', 'rails r MesTErpAccount.start still running')
    end
  end

  def self.check_mo_close
    sql = "select distinct order_id from t_erp_account where status = '10' group by order_id"
    order_ids = MesTErpAccount.find_by_sql(sql)
    order_ids.each do |row|
      mo_close = true
      aufnrs = row.order_id.split(',')
      aufnrs.each do |aufnr|
        sql = "select count(*) cnt from sapsr3.jest b where b.mandt='168' and b.objnr=? and b.inact=' ' and b.stat in ('I0045','I0046')"
        rows = Sapdb.find_by_sql([sql, "OR#{aufnr}"])
        if rows.first.cnt == 0
          mo_close = false
        end
      end
      if mo_close
        sql = "update t_erp_account set status='TK' where status = '10' and order_id = '#{row.order_id}'"
        MesTErpAccount.connection.execute(sql)
      end
    end
  end

  def self.adjustment
    MesTErpAccount.transaction do
      stk_returns = MesTErpAccount.where("status='10' and move_type='262' and quantity < 0").order(:order_id)
      stk_returns.each do |stk_return|
        MesTErpAccount.connection.execute("update t_erp_account set updated_time = sysdate where id=#{stk_return.id}")
        stk_return.ws_bal_qty = stk_return.quantity - stk_return.sap_posted_qty - stk_return.mes_inter_qty
        stk_return.ws_alloc_qty = 0

        if stk_return.ws_bal_qty < 0
          stk_issues = MesTErpAccount.where("status='10' and move_type='261' and quantity > 0")
                           .where(material: stk_return.material, order_id: stk_return.order_id, bacth: stk_return.bacth)
                           .order(:order_id)
          stk_issues.each do |stk_issue|
            stk_issue.ws_bal_qty = stk_issue.quantity - stk_issue.sap_posted_qty - stk_issue.mes_inter_qty
            stk_issue.ws_alloc_qty = 0
            if stk_issue.ws_bal_qty > 0
              ws_qty = stk_return.ws_bal_qty.abs > stk_issue.ws_bal_qty.abs ? stk_issue.ws_bal_qty.abs : stk_return.ws_bal_qty.abs
              stk_return.ws_alloc_qty -= ws_qty
              stk_return.ws_bal_qty += ws_qty
              stk_return.mes_inter_qty -= ws_qty
              stk_issue.ws_alloc_qty += ws_qty
              stk_issue.ws_bal_qty -= ws_qty
              stk_issue.mes_inter_qty += ws_qty
              MesTErpAccountIss.create(
                  uuid: UUID.new.generate(:compact),
                  tea_id: stk_return.id,
                  mblnr: 0,
                  mjahr: Time.now.strftime('%Y'),
                  zeile: 0,
                  matnr: stk_return.material,
                  charg: stk_return.bacth,
                  menge: ws_qty * -1,
                  werks: stk_return.plant,
                  lgort: 'MES',
                  rsnum: ' ',
                  rspos: 0,
                  vtweg: PoReceipt.vtweg(stk_return.plant)
              )
              MesTErpAccountIss.create(
                  uuid: UUID.new.generate(:compact),
                  tea_id: stk_issue.id,
                  mblnr: 0,
                  mjahr: Time.now.strftime('%Y'),
                  zeile: 0,
                  matnr: stk_issue.material,
                  charg: stk_issue.bacth,
                  menge: ws_qty,
                  werks: stk_issue.plant,
                  lgort: 'MES',
                  rsnum: ' ',
                  rspos: 0,
                  vtweg: PoReceipt.vtweg(stk_issue.plant)
              )
              stk_issue.status = 'X' if stk_issue.ws_bal_qty == 0
              stk_issue.save

              stk_return.status = 'X' if stk_return.ws_bal_qty == 0
              stk_return.save
            end
            break if stk_return.ws_bal_qty == 0
          end
        end
      end
    end
  end

  def self.mo_return
    stk_issues_hash = {}
    stk_returns = MesTErpAccount.where("status='10' and move_type='262' and quantity < 0").order(:order_id)
    stk_returns.each do |stk_return|
      MesTErpAccount.connection.execute("update t_erp_account set updated_time = sysdate where id=#{stk_return.id}")
      stk_return.ws_bal_qty = stk_return.quantity - stk_return.sap_posted_qty - stk_return.mes_inter_qty
      stk_return.ws_alloc_qty = 0
      stk_return.ws_movements = []
      if stk_return.ws_bal_qty < 0
        #find posted transactions
        key = "#{stk_return.order_id}.#{stk_return.material}.#{stk_return.bacth}.#{stk_return.plant}"
        if not stk_issues_hash.key?(key)
          sql = "
            select b.rsnum,b.rspos,b.werks,b.posnr,sum(b.menge) menge from t_erp_account a
              join t_erp_account_iss b on b.tea_id=a.id and b.mblnr <> '0' and b.aufnr='#{stk_return.order_id}'
            where a.material='#{stk_return.material}' and a.bacth='#{stk_return.bacth}' and a.plant='#{stk_return.plant}'
            group by b.rsnum,b.rspos,b.werks,b.posnr
            having sum(menge) > 0
            order by b.posnr desc
         "
          stk_issues = MesTErpAccount.find_by_sql(sql)
          stk_issues_hash[key] = stk_issues
        end
        stk_issues = stk_issues_hash[key]
        stk_issues.each do |stk_issue|
          ws_qty = stk_return.ws_bal_qty.abs > stk_issue.menge.abs ? stk_issue.menge.abs : stk_return.ws_bal_qty.abs
          stk_return.ws_alloc_qty -= ws_qty
          stk_return.ws_bal_qty += ws_qty
          stk_issue.menge -= ws_qty
          if ws_qty > 0
            sql = "
              select case when b.lgfsb = ' ' then b.lgpro else lgfsb end to_loc
                from sapsr3.marc b
                where b.mandt='168' and b.werks=? and b.matnr=?
             "
            marcs = Sapdb.find_by_sql([sql, stk_return.plant, stk_return.material])
            lgort = marcs.present? ? marcs.first.to_loc : 'MES'
            stk_return.ws_movements.append({
                                               rsnum: stk_issue.rsnum, rspos: stk_issue.rspos, rsart: ' ',
                                               lgort: lgort, menge: ws_qty, aufnr: stk_return.order_id, posnr: stk_issue.posnr,
                                               move_type: '262'
                                           })


          end
          break if stk_return.ws_bal_qty == 0
        end
      end
    end
    bapi_goodsmvt_create_261(stk_returns)
    # stk_returns.each do |account|
    #   account.ws_movements.each do |hash|
    #     puts hash
    #   end
    # end
  end


  def self.mo_issue
    sql = "select order_id from t_erp_account where status='10' and quantity > 0 and move_type='261' group by order_id order by order_id"
    MesTErpAccount.find_by_sql(sql).each do |order|
      mat_lot_refs = []
      mes_t_erp_accounts = MesTErpAccount
                               .where(status: '10', order_id: order.order_id).where("quantity > 0 and move_type='261' and ((sysdate - updated_time)*24*60) > 1")
                               .order(id: :asc)
      mes_t_erp_accounts.each do |row|
        MesTErpAccount.connection.execute("update t_erp_account set updated_time = sysdate where id=#{row.id}")
        row.ws_bal_qty = row.quantity - row.sap_posted_qty - row.mes_inter_qty
        row.ws_alloc_qty = 0
        row.ws_locations = []
        row.ws_movements = []
        mat_lot_ref = "('#{row.plant}','#{row.material}','#{row.bacth}')"
        mat_lot_refs.append mat_lot_ref unless mat_lot_refs.include?(mat_lot_ref)
      end

      # get sap current location stock on hand
      mchbs = {}
      while mat_lot_refs.present?
        sql = "
          select matnr,werks,lgort,charg,clabs from sapsr3.mchb
          where mandt='168' and (werks,matnr,charg) in (#{mat_lot_refs.pop(500).join(',')})
            and lgort not in ('RWNG','NNNN')
            and clabs > 0 order by lgort desc
        "
        Sapdb.find_by_sql(sql).each do |row|
          key = "#{row.werks}.#{row.matnr}.#{row.charg}"
          mchbs[key] = [] unless mchbs.key?(key)
          mchbs[key].append(row)
        end
      end
      sap_no_stocks = []
      orders = order.order_id.split(',')
      orders.each do |aufnr|
        sql = "
        select a.rsnum, a.rspos, a.matnr, a.werks, a.lgort, a.rsart,
               a.bdmng, a.enmng, (a.bdmng - a.enmng) bal_qty,
               a.posnr, d.arbpl, a.aufnr
          from sapsr3.resb a
                 join sapsr3.afvc  c on c.mandt=a.mandt and c.aufpl=a.aufpl and c.aplzl=a.aplzl
            left join sapsr3.crhd  d on d.mandt=c.mandt and d.objty='A' and d.objid=c.arbid and a.bdter between d.begda and d.endda
          where a.mandt='168' and a.dumps=' ' and a.bdmng <> 0 and a.xloek=' ' and a.aufnr=?
            order by a.matnr, a.posnr
        "
        resbs = Sapdb.find_by_sql([sql, aufnr])
        resbs.each do |resb|
          if resb.bal_qty > 0
            mes_t_erp_accounts.each do |row|

              if row.ws_bal_qty > 0 and
                  row.material.eql?(resb.matnr) and
                  (row.work_center.eql?(resb.arbpl) or (row.work_center[0..2].eql?(resb.arbpl[0..2]))) and
                  row.plant.eql?(resb.werks)

                key = "#{row.plant}.#{row.material}.#{row.bacth}"
                if mchbs.key?(key)
                  mchbs[key].each do |mchb|
                    if mchb.clabs > 0
                      mchb_qty = row.ws_bal_qty > mchb.clabs ? mchb.clabs : row.ws_bal_qty
                      resb_qty = resb.bal_qty > mchb_qty ? mchb_qty : resb.bal_qty
                      row.ws_bal_qty -= resb_qty
                      row.ws_alloc_qty += resb_qty
                      mchb.clabs -= resb_qty
                      resb.bal_qty -= resb_qty
                      if resb_qty > 0
                        row.ws_movements.append({
                                                    rsnum: resb.rsnum, rspos: resb.rspos, rsart: resb.rsart,
                                                    lgort: mchb.lgort, menge: resb_qty, aufnr: aufnr, posnr: resb.posnr
                                                })
                      end
                    end
                    break if row.ws_bal_qty == 0
                  end #mchbs[key].each do |mchb|
                end
              end


            end # mes_t_erp_accounts.each do |row|
          end #if resb.bal_qty > 0

          key = "#{resb.werks}.#{resb.matnr}.#{resb.arbpl}"
          sap_no_stocks.append(key) if resb.bal_qty > 0

        end # resbs.each do |resb|
      end
      bapi_goodsmvt_create_261(mes_t_erp_accounts)
      mes_t_erp_accounts.each do |account|
        key = "#{account.plant}.#{account.material}.#{account.work_center}"
        account.sap_no_stock = sap_no_stocks.include?(key) ? 'X' : 'F'
        account.save
      end
    end # MesTErpAccount.find_by_sql(sql).each do |order|
  end

  def self.mo_direct_posting
    sql = "select order_id from t_erp_account where status='10' and quantity > 0 and move_type='261' and (sap_add_resb_qty > 0 or sap_no_stock='X') group by order_id order by order_id"
    MesTErpAccount.find_by_sql(sql).each do |order|
      mat_lot_refs = []
      mes_t_erp_accounts = MesTErpAccount
                               .where(status: '10', order_id: order.order_id).where("quantity > 0 and move_type='261' and ((sysdate - updated_time)*24*60) > 0 and (sap_add_resb_qty > 0 or sap_no_stock='X')")
                               .order(id: :asc)
      mes_t_erp_accounts.each do |row|
        MesTErpAccount.connection.execute("update t_erp_account set updated_time = sysdate where id=#{row.id}")
        row.ws_bal_qty = row.quantity - row.sap_posted_qty - row.mes_inter_qty
        row.ws_alloc_qty = 0
        row.ws_locations = []
        row.ws_movements = []
        mat_lot_ref = "('#{row.plant}','#{row.material}','#{row.bacth}')"
        mat_lot_refs.append mat_lot_ref unless mat_lot_refs.include?(mat_lot_ref)
      end

      # get sap current location stock on hand
      mchbs = {}
      while mat_lot_refs.present?
        sql = "
          select matnr,werks,lgort,charg,clabs from sapsr3.mchb
          where mandt='168' and (werks,matnr,charg) in (#{mat_lot_refs.pop(500).join(',')})
            and lgort not in ('RWNG','NNNN')
            and clabs > 0
        "
        Sapdb.find_by_sql(sql).each do |row|
          key = "#{row.werks}.#{row.matnr}.#{row.charg}"
          mchbs[key] = [] unless mchbs.key?(key)
          mchbs[key].append(row)
        end
      end
      sap_no_stocks = []
      orders = order.order_id.split(',')
      orders.each do |aufnr|
        sql = "
        select a.rsnum, a.rspos, a.matnr, a.werks, a.lgort, a.rsart,
               a.bdmng, a.enmng, (a.bdmng - a.enmng) bal_qty,
               a.posnr, d.arbpl, a.aufnr
          from sapsr3.resb a
                 join sapsr3.afvc  c on c.mandt=a.mandt and c.aufpl=a.aufpl and c.aplzl=a.aplzl
            left join sapsr3.crhd  d on d.mandt=c.mandt and d.objty='A' and d.objid=c.arbid and a.bdter between d.begda and d.endda
          where a.mandt='168' and a.dumps=' ' and a.bdmng <> 0 and a.xloek=' ' and a.kzear=' ' and a.aufnr=?
      "
        resbs = Sapdb.find_by_sql([sql, aufnr])
        resbs.each do |resb|
          if resb.bal_qty > 0
            mes_t_erp_accounts.each do |row|
              if row.ws_bal_qty > 0 and
                  row.material.eql?(resb.matnr) and
                  row.work_center.eql?(resb.arbpl) and
                  row.plant.eql?(resb.werks)

                key = "#{row.plant}.#{row.material}.#{row.bacth}"
                if mchbs.key?(key)
                  mchbs[key].each do |mchb|
                    if mchb.clabs > 0
                      mchb_qty = row.ws_bal_qty > mchb.clabs ? mchb.clabs : row.ws_bal_qty
                      resb_qty = resb.bal_qty > mchb_qty ? mchb_qty : resb.bal_qty
                      row.ws_bal_qty -= resb_qty
                      row.ws_alloc_qty += resb_qty
                      mchb.clabs -= resb_qty
                      resb.bal_qty -= resb_qty
                      if resb_qty > 0
                        row.ws_movements.append({
                                                    rsnum: resb.rsnum, rspos: resb.rspos, rsart: resb.rsart,
                                                    lgort: mchb.lgort, menge: resb_qty, aufnr: aufnr, posnr: resb.posnr
                                                })
                      end
                    end
                    break if row.ws_bal_qty == 0
                  end #mchbs[key].each do |mchb|
                end
              end
            end # mes_t_erp_accounts.each do |row|
          end #if resb.bal_qty > 0

          key = "#{resb.werks}.#{resb.matnr}.#{resb.arbpl}"
          sap_no_stocks.append(key) if resb.bal_qty > 0

        end # resbs.each do |resb|
      end
      bapi_goodsmvt_create_261(mes_t_erp_accounts)
      mes_t_erp_accounts.each do |account|
        key = "#{account.plant}.#{account.material}.#{account.work_center}"
        account.sap_no_stock = sap_no_stocks.include?(key) ? 'X' : 'F'
        account.save
      end
    end # MesTErpAccount.find_by_sql(sql).each do |order|
  end

  def self.mes_overload

    completed_in_minutes = 60 * 4 * 1 #min
    # sql = "
    #   select b.id, a.project_id,a.sap_workcenter,b.material,b.balqty,
    #          a.due_date, b.plant
    #     from v_closed_mo a
    #       join t_erp_account b on b.order_id=a.project_id and b.work_center=a.sap_workcenter and b.status='10' and b.sap_add_resb_qty=0
    #     where
    #           a.is_check = 'Y'
    #       and b.work_center is not null
    #       and b.move_type='261'
    #       and ((b.balqty between 0 and 1000) or (b.overflow_flag = 'Y') or ((sysdate - a.due_date)*24*60) > #{completed_in_minutes})
    #     order by a.due_date desc,a.project_id,a.sap_workcenter,b.material
    # "
    sql = "
      select b.id, b.order_id project_id,b.work_center,a.sap_workcenter,b.material,b.balqty,b.sap_posted_qty,b.sap_no_stock,
                   a.due_date, b.plant, b.created_time
        from t_erp_account b
          left join v_closed_mo a on b.order_id=a.project_id and b.work_center=a.sap_workcenter and a.is_check = 'Y'
        where b.status='10' and b.sap_add_resb_qty=0
          and (
                (((sysdate - a.due_date)*24*60) > #{completed_in_minutes} and balqty < 2000)
             /*
             or (b.work_center like '%DIP%' and b.balqty < 1000 and (((sysdate - b.created_time)*24*60) > #{completed_in_minutes}))
              */
             )
        order by b.id "
    accounts = MesTErpAccount.find_by_sql(sql)
    accounts.each do |account|
      t_account = MesTErpAccount.find(account.id)
      sql = "
        select a.werks, a.matnr, d.arbpl, a.rsnum, a.rspos, a.potx2
          from sapsr3.resb a
            join sapsr3.afvc  c on c.mandt=a.mandt and c.aufpl=a.aufpl and c.aplzl=a.aplzl
            join sapsr3.crhd  d on d.mandt=c.mandt and d.objty='A' and d.objid=c.arbid and a.bdter between d.begda and d.endda
          where a.mandt='168' and a.dumps=' ' and a.bdmng <> 0 and a.xloek=' ' and a.aufnr=? and a.matnr=? and d.arbpl=? and a.werks=?
      "
      resbs = Sapdb.find_by_sql([sql, t_account.order_id, t_account.material, t_account.work_center, t_account.plant])
      record_created = false
      if resbs.present?
        key = "MES_TEA_ID:#{t_account.id}"
        puts key
        resbs.each do |resb|
          if resb.potx2.eql?(key)
            record_created = true
            t_account.sap_add_resb_qty = t_account.balqty
            t_account.save
            break
          end
        end

        if record_created == false and t_account.balqty > 0
          resb = resbs.first
          new_rspos = create_sap_resb(resb.rsnum, resb.rspos, t_account.balqty, key)
          if new_rspos.present?
            t_account.sap_add_resb_qty = t_account.balqty
            t_account.save
          end
        end
      end
    end
  end

  def self.bapi_goodsmvt_create_261(mes_t_erp_accounts)
    perform_posting = false
    mes_t_erp_accounts.each do |account|
      if account.ws_movements.present?
        perform_posting = true
        break
      end
    end
    return unless perform_posting

    begin
      dest = JCoDestinationManager.getDestination('sap_prd')
      repos = dest.getRepository
      commit = repos.getFunction('BAPI_TRANSACTION_COMMIT')
      commit.getImportParameterList().setValue('WAIT', 'X')

      function = repos.getFunction('BAPI_GOODSMVT_CREATE')
      function.getImportParameterList().getStructure('GOODSMVT_CODE').setValue('GM_CODE', '03')

      header = function.getImportParameterList().getStructure('GOODSMVT_HEADER')
      header.setValue('PSTNG_DATE', Date.today.strftime('%Y%m%d'))
      header.setValue('DOC_DATE', Date.today.strftime('%Y%m%d'))
      header.setValue('PR_UNAME', 'LUM.LIN')
      header.setValue('HEADER_TXT', 'MES MO ISSUE')

      lines = function.getTableParameterList().getTable('GOODSMVT_ITEM')
      line_id = 0
      mes_t_erp_accounts.each do |resb|
        resb.ws_movements.each do |hash|
          line_id = line_id + 10
          lines.appendRow()
          lines.setValue('LINE_ID', line_id)
          lines.setValue('MATERIAL', resb.material)
          lines.setValue('PLANT', resb.plant)
          lines.setValue('BATCH', resb.bacth)
          lines.setValue('STGE_LOC', hash[:lgort])
          lines.setValue('MOVE_TYPE', '261')
          if resb.move_type.eql?('262')
            lines.setValue('XSTOB', 'X')
            if hash[:posnr].include?('Z002')
              lines.setValue('NO_MORE_GR', 'X')
            end
          end
          lines.setValue('ORDERID', hash[:aufnr])
          lines.setValue('RESERV_NO', hash[:rsnum])
          lines.setValue('RES_ITEM', hash[:rspos])
          lines.setValue('RES_TYPE', hash[:rsart])
          lines.setValue('ENTRY_QNT', hash[:menge])
        end
      end

      com.sap.conn.jco.JCoContext.begin(dest)
      function.execute(dest)

      sap_msg_texts = []
      posting_success = true
      returnMessage = function.getTableParameterList().getTable('RETURN')
      (1..returnMessage.getNumRows).each do |i|
        puts "#{i} Type:#{returnMessage.getString('TYPE')}, MSG:#{returnMessage.getString('MESSAGE')}"
        if returnMessage.getString('TYPE').eql?('E')
          sap_msg_texts.append("#{i} Type:#{returnMessage.getString('TYPE')}, MSG:#{returnMessage.getString('MESSAGE')}")
          posting_success = false
        end
        returnMessage.nextRow
      end

      if posting_success
        mblnr = function.getExportParameterList().getString('MATERIALDOCUMENT')
        mjahr = function.getExportParameterList().getString('MATDOCUMENTYEAR')
        MesTErpAccount.transaction do
          line_id = 0
          mes_t_erp_accounts.each do |account|
            account.ws_movements.each do |hash|
              line_id += 10
              menge = account.move_type.eql?('262') ? hash[:menge] * -1 : hash[:menge]
              MesTErpAccountIss.create(
                  uuid: UUID.new.generate(:compact),
                  tea_id: account.id,
                  mblnr: mblnr,
                  mjahr: mjahr,
                  zeile: line_id,
                  matnr: account.material,
                  charg: account.bacth,
                  menge: menge,
                  werks: account.plant,
                  lgort: hash[:lgort],
                  rsnum: hash[:rsnum],
                  rspos: hash[:rspos],
                  aufnr: hash[:aufnr],
                  posnr: hash[:posnr],
                  vtweg: PoReceipt.vtweg(account.plant)
              )
              account.sap_posted_qty += menge
              account.status = 'X' if (account.sap_posted_qty + account.mes_inter_qty) == account.quantity
              account.save
            end
          end
        end
      else #posting error
        Mail.defaults do
          delivery_method :smtp, address: '172.91.1.253', port: 25
        end
        message = "#{sap_msg_texts.join('\n')}"

        Mail.deliver do
          from 'lum.cl@l-e-i.com'
          to 'lum.cl@l-e-i.com, ted.meng@l-e-i.com'
          subject 'mes_t_erp_account bapi_goodsmvt_create_261'
          body message
        end
      end
      commit.execute(dest)
      com.sap.conn.jco.JCoContext.end(dest)
    rescue Exception => exception
      Mail.defaults do
        delivery_method :smtp, address: '172.91.1.253', port: 25
      end
      message = "#{message} #{exception.message} #{exception.backtrace.join('\n')}"

      Mail.deliver do
        from 'lum.cl@l-e-i.com'
        to 'lum.cl@l-e-i.com, ted.meng@l-e-i.com'
        subject 'mes_t_erp_out_project bapi_goodsmvt_create_261'
        body message
      end

    end
  end

  def self.create_sap_resb(rsnum, rspos, bdmng, key)
    begin
      sql = "select nvl(max(rspos),8000) rspos from sapsr3.resb where mandt='168' and rsnum=? and rspos between '8000' and '9000'"
      resbs = Sapdb.find_by_sql([sql, rsnum])
      new_rspos = resbs.first.rspos.to_i + 1
      #new_rspos = rspos.to_i + 5000
      dest = JCoDestinationManager.getDestination('sap_prd')
      repos = dest.getRepository
      commit = repos.getFunction('BAPI_TRANSACTION_COMMIT')
      commit.getImportParameterList().setValue('WAIT', 'X')

      #function = repos.getFunction('Z_CREATE_RESERVATION')
      function = repos.getFunction('Z_RESERVATION_CREATE')
      lines = function.getTableParameterList().getTable('XRESB')

      sql = "select * from sapsr3.resb where mandt='168' and rsnum=? and rspos=? and rownum=1"
      resbs = Sapdb.find_by_sql([sql, rsnum, rspos])
      resbs.each do |resb|
        lines.appendRow()
        resb.attributes.each do |k, v|
          lines.setValue(k.upcase, v) if v.present?
        end
        lines.setValue('RSPOS', "#{new_rspos}")
        #lines.setValue('OBJNR', "OK#{rsnum}#{new_rspos}")
        lines.setValue('BDMNG', bdmng)
        lines.setValue('ENMNG', '')
        lines.setValue('ENWRT', '')
        lines.setValue('ERFMG', '')
        lines.setValue('VMENG', '')
        lines.setValue('KZEAR', 'X')
        lines.setValue('GPREIS', '')
        lines.setValue('GPREIS_2', '')
        lines.setValue('POTX2', key)
        lines.setValue('POTX1', 'MES_OVERLOAD')
        lines.setValue('POSNR', 'Z002')
      end
      com.sap.conn.jco.JCoContext.begin(dest)
      function.execute(dest)
      commit.execute(dest)
      com.sap.conn.jco.JCoContext.end(dest)

    rescue Exception => exception
      Mail.defaults do
        delivery_method :smtp, address: '172.91.1.253', port: 25
      end
      message = "#{message} #{exception.message} #{exception.backtrace.join('\n')}"

      Mail.deliver do
        from 'lum.cl@l-e-i.com'
        to 'lum.cl@l-e-i.com, ted.meng@l-e-i.com'
        subject "create_sap_resb #{rsnum} #{rspos}"
        body message
      end
      new_rspos = nil
    end
    new_rspos
  end

  def self.close_mes_overload
    close_resbs = []
    sql = "
      select b.rsnum,b.rspos,b.potx2
        from sapsr3.resb b
      where b.mandt='168' and b.xloek=' ' and b.kzear=' ' and b.posnr='Z002' and b.potx1='MES_OVERLOAD'
    "
    Sapdb.find_by_sql(sql).each do |row|
      need_to_close = true
      if row.potx2.include?('MES_TEA_ID')
        id = row.potx2.split(":").second.split(".").first
        sql = "select status from t_erp_account where id=#{id}"
        t_erp_account = MesTErpAccount.find_by_sql(sql)
        if t_erp_account.present?
          need_to_close = false if t_erp_account.first.status.eql?('10')
        end
      end
      close_resbs.append row if need_to_close
    end
    update_resb_kzear(close_resbs)
  end

  def self.update_resb_kzear(imp_dats)
    begin
      dest = JCoDestinationManager.getDestination('sap_prd')
      repos = dest.getRepository
      commit = repos.getFunction('BAPI_TRANSACTION_COMMIT')
      commit.getImportParameterList().setValue('WAIT', 'X')

      function = repos.getFunction('Z_UPD_RESB')
      lines = function.getTableParameterList().getTable('IMP_DAT')
      imp_dats.each do |row|
        puts "#{row.rsnum}.#{row.rspos}"
        lines.appendRow()
        lines.setValue('RSNUM', row.rsnum)
        lines.setValue('RSPOS', row.rspos)
        lines.setValue('KZEAR', 'X')
      end
      com.sap.conn.jco.JCoContext.begin(dest)
      function.execute(dest)
      commit.execute(dest)
      com.sap.conn.jco.JCoContext.end(dest)
    rescue Exception => exception
      Mail.defaults do
        delivery_method :smtp, address: '172.91.1.253', port: 25
      end
      message = "#{message} #{exception.message} #{exception.backtrace.join('\n')}"

      Mail.deliver do
        from 'lum.cl@l-e-i.com'
        to 'lum.cl@l-e-i.com, ted.meng@l-e-i.com'
        subject "create_sap_resb #{rsnum} #{rspos}"
        body message
      end
    end
  end

  def self.send_email(subject, message)
    Mail.defaults do
      delivery_method :smtp, address: '172.91.1.253', port: 25
    end
    Mail.deliver do
      from 'lum.cl@l-e-i.com'
      to 'lum.cl@l-e-i.com, ted.meng@l-e-i.com'
      subject subject
      body message
    end
  end

end