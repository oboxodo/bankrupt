#!/usr/bin/env ruby

require "net/http"
require "csv"
require "json"
require "date"

class Bankrupt
  def initialize(cookie)
    @accounts_url = "https://www.itaulink.com.uy/trx/"
    @credit_cards_url = "https://www.itaulink.com.uy/trx/tarjetas/credito"
    @http = setup_http
    @cookie = cookie.split("; ")[0]
    @ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36"
  end

  def self.fetch_data(cookie, year, month)
    client = new(cookie)
    client.export_all_data(year, month)
  end

  def export_all_data(year, month)
    export_accounts(year, month)
    export_credit_cards(year, month)
  end

  private

  def setup_http
    uri = URI.parse("https://www.itaulink.com.uy/")
    http = Net::HTTP.new(uri.host, uri.port)
    http.set_debug_output $stdout if ENV["DEBUG"]
    http.use_ssl = true
    http
  end

  def get(url, headers = {})
    uri = URI.parse(url)
    request = Net::HTTP::Get.new(uri.request_uri, headers)
    request["Cookie"] = @cookie if @cookie
    request["User-Agent"] = @ua if @ua
    @http.request(request)
  end

  def post(url, data = nil)
    uri = URI.parse(url)
    request = Net::HTTP::Post.new(uri.request_uri)
    request.set_form_data(data) if data
    request["Cookie"] = @cookie if @cookie
    request["User-Agent"] = @ua if @ua
    @http.request(request)
  end

  def fetch_accounts
    response = get(@accounts_url)
    json_string = response.body[/var mensajeUsuario = JSON.parse\('(.*)'\);/, 1]
    json = JSON.parse(json_string)
    accounts = []

    json["cuentas"].each do |account_type, accounts_data|
      accounts_data.each do |account_data|
        accounts << {
          type_name: account_type,
          type: account_data["tipoCuenta"],
          hash: account_data["hash"],
          currency: account_data["moneda"],
          number: account_data["idCuenta"],
          balance: account_data["saldo"],
          filename: "#{account_type.downcase}-#{account_data['idCuenta']}-#{account_data['moneda']}"
        }
      end
    end

    puts "Found #{accounts.size} accounts. (#{accounts.map { |a| a[:number] }.join(',')})"
    accounts
  end

  def fetch_credit_cards
    json_string = post(@credit_cards_url).body
    json = JSON.parse(json_string)
    cards = []

    json["itaulink_msg"]["data"]["objetosTarjetaCredito"]["tarjetaImagen"].map(&:first).each do |card_data|
      cards << {
        brand: card_data["selloFormateado"],
        owner_id: card_data["numeroDocumentoTitular"],
        hash: card_data["hash"],
        account: card_data["nroCuenta"],
        id: card_data["id"],
        filename: ["credit_card", card_data["id"], card_data["numeroDocumentoTitular"]].join("-").downcase
      }
    end

    puts "Found #{cards.size} credit cards. (#{cards.map { |c| c[:hash] }.join(',')})"
    cards
  end

  def export_accounts(year, month)
    puts "\nFetching accounts information..."
    fetch_accounts.each do |account|
      export_account_data(account, year, month)
    end
  end

  def export_credit_cards(year, month)
    puts "\nFetching credit cards information..."
    fetch_credit_cards.uniq { |cc| cc[:account] }.each do |cc|
      ["Pesos", "Dolares"].each do |currency|
        export_credit_card_data(cc, currency, year, month)
      end
    end
  end

  def export_account_data(account, year, month)
    filename = "#{[account[:filename], year, month].compact.join('-')}.csv"
    csv_data = generate_account_csv(account, year, month)
    File.write(filename, csv_data)
    puts "#{filename} exported"
  end

  def export_credit_card_data(cc, currency, year, month)
    filename = "#{[cc[:filename], currency, year, month].compact.join('-')}.csv"
    csv_data = generate_credit_card_csv(cc, year, month, currency)
    File.write(filename, csv_data)
    puts "#{filename} exported"
  end

  def generate_account_csv(account, year, month)
    csv_data = %w[Date Payee Category Memo Outflow Inflow].to_csv
    transactions = fetch_account_transactions(account, year, month)

    transactions.each do |tx|
      csv_data << [
        tx[:date],
        tx[:description],
        "",
        tx[:description],
        [0, tx[:amount]].min * -1,
        [0, tx[:amount]].max
      ].to_csv
    end

    csv_data
  end

  def generate_credit_card_csv(cc, year, month, currency)
    csv_data = %w[Date Payee Category Memo Outflow Inflow].to_csv
    transactions = fetch_credit_card_transactions(cc, year, month, currency)

    transactions.each do |tx|
      instalment_suffix = tx[:instalment] ? " #{tx[:instalment]}/#{tx[:instalments]}" : ""
      csv_data << [
        tx[:date],
        tx[:description],
        "",
        tx[:description] + instalment_suffix,
        [0, tx[:amount]].min * -1,
        [0, tx[:amount]].max
      ].to_csv
    end

    csv_data
  end

  def fetch_account_transactions(account, year, month)
    url = account_transactions_url(account, year, month)
    puts "Downloading from: #{url}"
    transactions = []

    get(url).body.each_line do |line|
      data = line.chomp.unpack("a7a4a7a2a15a15a*")
      date = Date.parse(data[2])
      description = data[6].gsub(/\s\s*/, " ")
      next if skip_account_transaction?(description) || date > Date.today

      transactions << {
        date: date,
        amount: data[5].to_f - data[4].to_f,
        description: description
      }
    end

    transactions
  end

  def fetch_credit_card_transactions(cc, year, month, currency)
    url = credit_card_transactions_url(cc, year, month)
    puts "Downloading from: #{url}"

    json_string = get(url).body
    txns = JSON.parse(json_string)["itaulink_msg"]["data"]["datos"]["datosMovimientos"]["movimientos"]

    txns.select { |t| t["moneda"] == currency }.map do |tx|
      fecha = tx["fecha"]
      date = Date.new(fecha["year"], fecha["monthOfYear"], fecha["dayOfMonth"])
      description = tx["nombreComercio"]
      next if skip_credit_card_transaction?(description) || date > Date.today

      {
        date: date,
        amount: tx["importe"] * -1,
        description: description,
        instalment: tx["tipo"] == "Plan Pagos" ? tx["nroCuota"] : nil,
        instalments: tx["tipo"] == "Plan Pagos" ? tx["cantCuotas"] : nil
      }
    end.compact
  end

  def account_transactions_url(account, year, month)
    base_url = "https://www.itaulink.com.uy/trx/cuentas/#{account[:type]}/#{account[:hash]}"
    "#{base_url}/reporteEstadoCta/TXT?anio=#{year}&mes=#{month}"
  end

  def credit_card_transactions_url(cc, year, month)
    "https://www.itaulink.com.uy/trx/tarjetas/credito/#{cc[:hash]}/movimientos_actuales/#{year}#{month}00"
  end

  def skip_account_transaction?(description)
    [/^CONCEPTO/, /^SALDO INICIAL/, /^SALDO FINAL/].any? { |e| description.to_s.strip.match?(e) }
  end

  def skip_credit_card_transaction?(description)
    description.to_s.strip.match?(/^Recibo de Pago$/)
  end
end

if __FILE__ == $PROGRAM_NAME
  cookie = ARGV.fetch(0, ENV["COOKIE"])
  year = ARGV.fetch(1, ENV["YEAR"])
  month = ARGV.fetch(2, ENV["MONTH"])

  Bankrupt.fetch_data(cookie, year, month)
end
