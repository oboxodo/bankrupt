#!/usr/bin/env ruby

require "net/http"
require "csv"
require "json"
require "date"

class HttpClient
  def initialize(cookie, ua)
    @cookie = cookie
    @ua = ua
    @http = setup_http
  end

  def get(url, headers = {})
    make_request(Net::HTTP::Get, url, headers)
  end

  def post(url, data = nil)
    make_request(Net::HTTP::Post, url, data)
  end

  private

  def make_request(request_class, url, data)
    uri = URI.parse(url)
    request = request_class.new(uri.request_uri)
    request.set_form_data(data) if data && request_class == Net::HTTP::Post
    request["Cookie"] = @cookie if @cookie
    request["User-Agent"] = @ua if @ua
    @http.request(request)
  end

  def setup_http
    uri = URI.parse("https://www.itaulink.com.uy/")
    http = Net::HTTP.new(uri.host, uri.port)
    http.set_debug_output $stdout if ENV["DEBUG"]
    http.use_ssl = true
    http
  end
end

class Transaction
  attr_reader :date, :description, :amount, :instalment, :instalments

  def initialize(date:, description:, amount:, instalment: nil, instalments: nil)
    @date = date
    @description = description
    @amount = amount
    @instalment = instalment
    @instalments = instalments
  end

  def to_csv_row
    instalment_suffix = instalment ? " #{instalment}/#{instalments}" : ""
    [
      date,
      description,
      "",
      description + instalment_suffix,
      [0, amount].min * -1,
      [0, amount].max
    ]
  end
end

class CsvExporter
  HEADERS = %w[Date Payee Category Memo Outflow Inflow].freeze

  def self.export(filename, transactions)
    csv_data = HEADERS.to_csv
    transactions.each do |tx|
      csv_data << tx.to_csv_row.to_csv
    end

    File.write(filename, csv_data)
    puts "#{filename} exported"
  end
end

class ItauUruguay
  BASE_URL = "https://www.itaulink.com.uy".freeze
  CURRENCIES = ["Pesos", "Dolares"].freeze

  def initialize(cookie)
    @accounts_url = "#{BASE_URL}/trx/"
    @credit_cards_url = "#{BASE_URL}/trx/tarjetas/credito"
    @http_client = HttpClient.new(
      cookie.split("; ")[0],
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36"
    )
  end

  def self.export_transactions(cookie, year, month)
    new(cookie).export_all_data(year, month)
  end

  def export_all_data(year, month)
    export_accounts(year, month)
    export_credit_cards(year, month)
  end

  private

  def fetch_accounts
    response = @http_client.get(@accounts_url)
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
    json_string = @http_client.post(@credit_cards_url).body
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
      filename = "#{[account[:filename], year, month].compact.join('-')}.csv"
      transactions = fetch_account_transactions(account, year, month)
      CsvExporter.export(filename, transactions)
    end
  end

  def export_credit_cards(year, month)
    puts "\nFetching credit cards information..."
    fetch_credit_cards.uniq { |cc| cc[:account] }.each do |cc|
      CURRENCIES.each do |currency|
        filename = "#{[cc[:filename], currency, year, month].compact.join('-')}.csv"
        transactions = fetch_credit_card_transactions(cc, year, month, currency)
        CsvExporter.export(filename, transactions)
      end
    end
  end

  def fetch_account_transactions(account, year, month)
    url = account_transactions_url(account, year, month)
    puts "Downloading from: #{url}"
    transactions = []

    @http_client.get(url).body.each_line do |line|
      data = line.chomp.unpack("a7a4a7a2a15a15a*")
      date = Date.parse(data[2])
      description = data[6].gsub(/\s\s*/, " ")
      next if skip_account_transaction?(description) || date > Date.today

      transactions << Transaction.new(
        date: date,
        description: description,
        amount: data[5].to_f - data[4].to_f
      )
    end

    transactions
  end

  def fetch_credit_card_transactions(cc, year, month, currency)
    url = credit_card_transactions_url(cc, year, month)
    puts "Downloading from: #{url}"

    json_string = @http_client.get(url).body
    txns = JSON.parse(json_string)["itaulink_msg"]["data"]["datos"]["datosMovimientos"]["movimientos"]

    txns.select { |t| t["moneda"] == currency }.map do |tx|
      fecha = tx["fecha"]
      date = Date.new(fecha["year"], fecha["monthOfYear"], fecha["dayOfMonth"])
      description = tx["nombreComercio"]
      next if skip_credit_card_transaction?(description) || date > Date.today

      Transaction.new(
        date: date,
        description: description,
        amount: tx["importe"] * -1,
        instalment: tx["tipo"] == "Plan Pagos" ? tx["nroCuota"] : nil,
        instalments: tx["tipo"] == "Plan Pagos" ? tx["cantCuotas"] : nil
      )
    end.compact
  end

  def account_transactions_url(account, year, month)
    base_url = "#{BASE_URL}/trx/cuentas/#{account[:type]}/#{account[:hash]}"
    "#{base_url}/reporteEstadoCta/TXT?anio=#{year}&mes=#{month}"
  end

  def credit_card_transactions_url(cc, year, month)
    "#{BASE_URL}/trx/tarjetas/credito/#{cc[:hash]}/movimientos_actuales/#{year}#{month}00"
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

  ItauUruguay.export_transactions(cookie, year, month)
end
